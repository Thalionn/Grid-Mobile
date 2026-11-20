import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veilid/veilid.dart';

/// Veilid integration for the P2P app.
///
/// Identity is a local keypair; contacts are imported private routes. Location
/// is shared by sending JSON app messages over those routes, and received via
/// the Veilid update stream.
class VeilidService {
  VeilidService._();
  static final VeilidService instance = VeilidService._();

  bool _started = false;
  String? _identity;
  VeilidRoutingContext? _routingContext;
  StreamSubscription<VeilidUpdate>? _updateSub;
  final List<RouteId> _contacts = [];
  // Base64url route blobs we've imported, persisted so contacts survive a
  // restart. Kept in sync with [_contacts].
  final List<String> _contactBlobs = [];

  static const _contactsPrefKey = 'veilid_contacts';

  // Latest location per contact, keyed by the receiving route id (the route
  // this node created and shared). In-memory for the spike.
  final Map<String, Map<String, dynamic>> _contactLocations = {};

  final StreamController<Map<String, dynamic>> _locationController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Received contact locations, as maps with `lat`, `lng`, `accuracy`,
  /// `routeId`, and `sender`.
  Stream<Map<String, dynamic>> get locationUpdates =>
      _locationController.stream;

  /// Latest location per contact (keyed by route id), for map markers.
  Map<String, Map<String, dynamic>> get contactLocations =>
      Map.unmodifiable(_contactLocations);

  Future<void>? _starting;

  /// Starts Veilid exactly once, even when called concurrently (the identity
  /// screen loads identity and the share blob in parallel).
  Future<void> _ensureStarted() {
    if (_started) return Future.value();
    return _starting ??= _doStart().whenComplete(() => _starting = null);
  }

  Future<void> _doStart() async {
    const platformConfig = VeilidFFIConfig(
      logging: VeilidFFIConfigLogging(
        terminal: VeilidFFIConfigLoggingTerminal(
          enabled: false,
          level: VeilidConfigLogLevel.debug,
        ),
        api: VeilidFFIConfigLoggingApi(
          enabled: true,
          level: VeilidConfigLogLevel.info,
        ),
      ),
    );
    Veilid.instance.initializeVeilidCore(platformConfig.toJson());

    final config = await getDefaultVeilidConfig(
      isWeb: kIsWeb,
      programName: 'Grid',
    );
    // The Android Keystore-backed secure store can be unavailable (locked or
    // unsupported), and the default config refuses to fall back. Allow the
    // disk-based fallback so the node can still boot.
    final patched = config.copyWith(
      protectedStore: config.protectedStore.copyWith(
        allowInsecureFallback: true,
      ),
    );

    final updates = await Veilid.instance.startupVeilidCore(patched);
    _routingContext = await Veilid.instance.routingContext();
    _updateSub = updates.listen(_handleUpdate);
    await Veilid.instance.attach();

    _started = true;

    // Re-import persisted contacts. Local import, no network round-trip.
    await _restoreContacts();
  }

  Future<void> _restoreContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final blobs = prefs.getStringList(_contactsPrefKey) ?? const <String>[];
    if (blobs.isNotEmpty) {
      debugPrint('[Veilid] restoring ${blobs.length} saved contact(s)');
    }
    for (final blobB64 in blobs) {
      try {
        final blob = base64Url.decode(blobB64);
        final routeId = await Veilid.instance.importRemotePrivateRoute(blob);
        final id = routeId.toString();
        if (!_contacts.any((r) => r.toString() == id)) {
          _contacts.add(routeId);
        }
        if (!_contactBlobs.contains(blobB64)) {
          _contactBlobs.add(blobB64);
        }
      } catch (e) {
        debugPrint('[Veilid] restore contact failed: $e');
      }
    }
  }

  Future<void> _persistContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_contactsPrefKey, _contactBlobs);
  }

  void _handleUpdate(VeilidUpdate update) {
    if (update is! VeilidAppMessage) return;
    try {
      final payload = jsonDecode(utf8.decode(update.message));
      if (payload is Map && payload['type'] == 'location') {
        final loc = {
          'lat': (payload['lat'] as num).toDouble(),
          'lng': (payload['lng'] as num).toDouble(),
          'accuracy': (payload['accuracy'] as num?)?.toDouble(),
          'routeId': update.routeId,
          'sender': update.sender?.toString(),
          'ts': DateTime.now(),
        };
        _locationController.add(loc);
        final key = update.routeId ?? update.sender?.toString() ?? 'unknown';
        _contactLocations[key] = loc;
      }
    } catch (_) {
      // Ignore malformed/unexpected messages.
    }
  }

  /// Returns a stable identity string (a Veilid public key) suitable for
  /// rendering into a QR code. Generates one on first use.
  Future<String> identity() async {
    if (_identity != null) return _identity!;
    await _ensureStarted();
    final keypair = await Veilid.instance.generateKeyPair(cryptoKindVLD0);
    _identity = keypair.key.toString();
    return _identity!;
  }

  /// Returns a fresh private-route import blob, base64url encoded, for a
  /// contact to scan. A new route is allocated on every call because Veilid
  /// private routes are ephemeral: one allocated in a previous session is dead
  /// after the node restarts. (A stable, restarts-surviving address needs the
  /// DHT "rendezvous" pattern — publish the current blob under a stable record
  /// key — which is not implemented yet.)
  Future<String> shareRouteBlobB64() async {
    await _ensureStarted();
    // A route can only be allocated once the node is attached with a
    // PublicInternet network class (otherwise newPrivateRoute throws TryAgain).
    await Veilid.instance.waitForAttachmentCondition(
      timeout: const Duration(seconds: 30),
    );
    final route = await Veilid.instance.newPrivateRoute();
    return base64Url.encode(route.blob);
  }

  /// Imports a scanned private-route blob (base64url) as a new contact.
  Future<void> importContact(String blobB64) async {
    await _ensureStarted();
    final blob = base64Url.decode(blobB64);
    final routeId = await Veilid.instance.importRemotePrivateRoute(blob);
    final id = routeId.toString();
    if (!_contacts.any((r) => r.toString() == id)) {
      _contacts.add(routeId);
    }
    if (!_contactBlobs.contains(blobB64)) {
      _contactBlobs.add(blobB64);
      await _persistContacts();
    }
  }

  /// Sends the current location to every contact over their private route.
  Future<void> sendLocation(double lat, double lng, {double? accuracy}) async {
    await _ensureStarted();
    final context = _routingContext;
    if (context == null || _contacts.isEmpty) return;
    final payload = jsonEncode({
      'type': 'location',
      'lat': lat,
      'lng': lng,
      'accuracy': accuracy,
      'ts': DateTime.now().toIso8601String(),
    });
    final bytes = Uint8List.fromList(utf8.encode(payload));
    for (final routeId in _contacts) {
      try {
        await context.appMessage(TargetRouteId(routeId: routeId), bytes);
      } catch (e) {
        debugPrint('[Veilid] sendLocation failed for ${routeId.toString()}: $e');
      }
    }
  }

  /// Imported contact route ids, as strings (in-memory for the spike).
  List<String> get contactRouteIds =>
      List.unmodifiable(_contacts.map((r) => r.toString()));
}
