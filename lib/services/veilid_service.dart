import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veilid/veilid.dart';
import 'package:grid_frontend/models/location_history.dart';
import 'package:grid_frontend/repositories/location_history_repository.dart';

/// Veilid integration for the P2P app.
///
/// A user's stable address is a DHT record key (owned by a local keypair).
/// Private routes are ephemeral, so each node publishes its *current* route
/// blob to that record (the "rendezvous" pattern): a contact looks up the
/// address's record to find the live route. Location is shared over those
/// routes via JSON app messages.
class VeilidService {
  VeilidService._();
  static final VeilidService instance = VeilidService._();

  bool _started = false;
  KeyPair? _keyPair;
  RecordKey? _myRecordKey;
  VeilidRoutingContext? _routingContext;
  StreamSubscription<VeilidUpdate>? _updateSub;

  // Stable contact addresses (DHT record key strings), persisted. The live
  // route for each contact is looked up from their DHT record on demand.
  final List<String> _contactAddresses = [];
  final Map<String, RouteId> _contactRoutes = {}; // address -> imported route

  static const _contactsPrefKey = 'veilid_contacts';
  static const _myRecordKeyPrefKey = 'veilid_my_record_key';
  // User-secret key (Veilid protected store) for the identity keypair.
  static const _myKeyPairSecretKey = 'grid_identity_keypair';

  // Device-local trail recorder, attached at boot. Optional: recording is
  // best-effort and skipped when it isn't wired up.
  LocationHistoryRepository? _historyRepo;

  // My current route id, so a RouteChange update can tell when it died.
  String? _myRouteId;
  bool _republishing = false;

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
  /// screen loads the address and publishes the route in parallel).
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

    // Restore persisted contacts (their stable addresses) and re-resolve their
    // current routes from the DHT. Tolerant: offline contacts stay listed but
    // unresolved until the next send.
    await _restoreContacts();
  }

  Future<void> _restoreContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final addresses = prefs.getStringList(_contactsPrefKey) ?? const <String>[];
    if (addresses.isNotEmpty) {
      debugPrint('[Veilid] restoring ${addresses.length} saved contact(s)');
    }
    for (final address in addresses) {
      if (!_contactAddresses.contains(address)) {
        _contactAddresses.add(address);
      }
      try {
        _contactRoutes[address] = await _importContactRoute(address);
      } catch (e) {
        debugPrint('[Veilid] restore contact route failed for $address: $e');
      }
    }
  }

  Future<void> _persistContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_contactsPrefKey, _contactAddresses);
  }

  void _handleUpdate(VeilidUpdate update) {
    if (update is VeilidAppMessage) {
      _handleAppMessage(update);
    } else if (update is VeilidUpdateRouteChange) {
      _handleRouteChange(update);
    }
  }

  /// When my published route dies, mint a fresh one and rewrite my DHT record
  /// so contacts always resolve a live route.
  void _handleRouteChange(VeilidUpdateRouteChange update) {
    final mine = _myRouteId;
    if (mine == null || !update.deadRoutes.contains(mine)) return;
    if (_republishing) return;
    _republishing = true;
    unawaited(publishMyRoute().catchError((Object e) {
      debugPrint('[Veilid] route republish failed: $e');
    }).whenComplete(() => _republishing = false));
  }

  void _handleAppMessage(VeilidAppMessage update) {
    try {
      final payload = jsonDecode(utf8.decode(update.message));
      if (payload is Map && payload['type'] == 'location') {
        final lat = (payload['lat'] as num).toDouble();
        final lng = (payload['lng'] as num).toDouble();
        final from = payload['from'] as String?;
        final loc = {
          'lat': lat,
          'lng': lng,
          'accuracy': (payload['accuracy'] as num?)?.toDouble(),
          'from': from,
          'routeId': update.routeId,
          'sender': update.sender?.toString(),
          'ts': DateTime.now(),
        };
        _locationController.add(loc);
        final key = from ?? update.routeId ?? update.sender?.toString() ?? 'unknown';
        _contactLocations[key] = loc;
        // Record the sender's trail to device-local history (best-effort).
        if (from != null) _recordHistory(from, lat, lng);
      }
    } catch (_) {
      // Ignore malformed/unexpected messages.
    }
  }

  void _recordHistory(String address, double lat, double lng) {
    final repo = _historyRepo;
    if (repo == null) return;
    // Fire-and-forget; a keychain/DB hiccup must not break location delivery.
    unawaited(repo.addLocationPoint(address, lat, lng).catchError((Object e) {
      debugPrint('[Veilid] history record failed for $address: $e');
    }));
  }

  /// Returns my identity keypair, persisted in Veilid's protected store so it
  /// survives restarts (Keystore-backed on real devices).
  ///
  /// Veilid's generateKeyPair mints a *fresh random* pair each call (it does
  /// not persist), so we store it ourselves; otherwise the writer keypair would
  /// stop matching our DHT record's owner after a restart.
  Future<KeyPair> _keyPairOrCreate() async {
    if (_keyPair != null) return _keyPair!;
    final saved = await Veilid.instance.loadUserSecret(_myKeyPairSecretKey);
    if (saved != null && saved.isNotEmpty) {
      try {
        _keyPair = KeyPair.fromString(utf8.decode(saved));
        return _keyPair!;
      } catch (_) {
        // Fall through and mint a fresh pair.
      }
    }
    final kp = await Veilid.instance.generateKeyPair(cryptoKindVLD0);
    _keyPair = kp;
    await Veilid.instance.saveUserSecret(
      _myKeyPairSecretKey,
      Uint8List.fromList(utf8.encode(kp.toString())),
    );
    return kp;
  }

  /// Returns my stable address: the DHT record key I publish my current route
  /// to. Created once and persisted, so it survives restarts.
  Future<String> myAddress() async {
    await _ensureStarted();
    return (await _myRecordKeyOrCreate()).toString();
  }

  Future<RecordKey> _myRecordKeyOrCreate() async {
    if (_myRecordKey != null) return _myRecordKey!;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_myRecordKeyPrefKey);
    if (saved != null && saved.isNotEmpty) {
      try {
        _myRecordKey = RecordKey.fromString(saved);
        return _myRecordKey!;
      } catch (_) {
        // Fall through and recreate a fresh record.
      }
    }
    final kp = await _keyPairOrCreate();
    final context = _routingContext!;
    final desc = await context.createDHTRecord(
      cryptoKindVLD0,
      DHTSchema.dflt(oCnt: 1),
      owner: kp,
    );
    _myRecordKey = desc.key;
    await prefs.setString(_myRecordKeyPrefKey, desc.key.toString());
    return _myRecordKey!;
  }

  /// Allocate a fresh private route and publish its blob to my DHT record so
  /// contacts can reach me by looking up my stable address. Call on startup
  /// (and again if the route dies).
  Future<void> publishMyRoute() async {
    await _ensureStarted();
    // A route can only be allocated once the node is attached with a
    // PublicInternet network class (otherwise newPrivateRoute throws TryAgain).
    await Veilid.instance.waitForAttachmentCondition(
      timeout: const Duration(seconds: 30),
    );
    final route = await Veilid.instance.newPrivateRoute();
    _myRouteId = route.routeId.toString();
    final kp = await _keyPairOrCreate();
    final recordKey = await _myRecordKeyOrCreate();
    final context = _routingContext!;
    await context.openDHTRecord(recordKey, writer: kp);
    await context.setDHTValue(
      recordKey,
      0,
      route.blob,
      options: SetDHTValueOptions(writer: kp),
    );
    debugPrint('[Veilid] published route to DHT');
  }

  /// Record my own location to the device-local trail (keyed by my address).
  /// Best-effort; the repo throttles points internally.
  Future<void> recordMyLocation(double lat, double lng) async {
    final repo = _historyRepo;
    if (repo == null) return;
    final address = await myAddress();
    unawaited(repo.addLocationPoint(address, lat, lng).catchError((Object e) {
      debugPrint('[Veilid] my history record failed: $e');
    }));
  }

  /// Look up a contact's current route blob from their DHT record and import
  /// it, returning the route id to send on.
  Future<RouteId> _importContactRoute(String address) async {
    final recordKey = RecordKey.fromString(address);
    final context = _routingContext!;
    await context.openDHTRecord(recordKey);
    final value = await context.getDHTValue(recordKey, 0, forceRefresh: true);
    if (value == null || value.data.isEmpty) {
      throw StateError('Contact has no published route');
    }
    return Veilid.instance.importRemotePrivateRoute(value.data);
  }

  /// Add a contact by their stable address (a DHT record key string).
  Future<void> addContact(String address) async {
    await _ensureStarted();
    final routeId = await _importContactRoute(address);
    _contactRoutes[address] = routeId;
    if (!_contactAddresses.contains(address)) {
      _contactAddresses.add(address);
      await _persistContacts();
    }
  }

  /// Sends the current location to every contact, resolving each one's current
  /// route from their DHT record first (so a route that died or was rebuilt is
  /// picked up).
  Future<void> sendLocation(double lat, double lng, {double? accuracy}) async {
    await _ensureStarted();
    final context = _routingContext;
    if (context == null || _contactAddresses.isEmpty) return;
    final payload = jsonEncode({
      'type': 'location',
      'lat': lat,
      'lng': lng,
      'accuracy': accuracy,
      'from': await myAddress(),
      'ts': DateTime.now().toIso8601String(),
    });
    final bytes = Uint8List.fromList(utf8.encode(payload));
    for (final address in _contactAddresses) {
      try {
        final routeId = await _importContactRoute(address);
        _contactRoutes[address] = routeId;
        await context.appMessage(TargetRouteId(routeId: routeId), bytes);
      } catch (e) {
        debugPrint('[Veilid] sendLocation failed for $address: $e');
      }
    }
  }

  /// Contact addresses (DHT record key strings), as stored.
  List<String> get contactAddresses => List.unmodifiable(_contactAddresses);

  /// Attach the device-local location history repo so received contact
  /// locations are recorded as trails. Called once at boot.
  void attachHistoryRepo(LocationHistoryRepository repo) {
    _historyRepo = repo;
  }

  /// Emits the address of a trail that just gained a point, after the write,
  /// so the map can refresh polylines promptly. Null when no repo is attached.
  Stream<String>? get historyUpdates => _historyRepo?.historyUpdates;

  /// Load the recorded trails (location points) for my own address and every
  /// contact, keyed by address. Empty when the history repo isn't wired up.
  Future<Map<String, List<LocationPoint>>> loadTrails() async {
    final repo = _historyRepo;
    if (repo == null) return {};
    final addresses = [..._contactAddresses];
    final mine = await myAddress();
    if (!addresses.contains(mine)) addresses.add(mine);
    final histories = await repo.getLocationHistoriesForAddresses(addresses);
    return histories.map((address, h) => MapEntry(address, h.points));
  }
}
