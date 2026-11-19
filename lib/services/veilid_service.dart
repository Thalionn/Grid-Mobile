import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
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

  Future<void> _ensureStarted() async {
    if (_started) return;

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

  /// Creates a fresh private route and returns its import blob, base64url
  /// encoded so it can be rendered as a QR for a contact to scan.
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
