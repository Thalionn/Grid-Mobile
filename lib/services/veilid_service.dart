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
  final Map<String, DateTime> _contactRouteResolvedAt = {};

  // Addresses the user has paused (per-contact sharing off), persisted.
  final Set<String> _pausedAddresses = {};

  static const _contactsPrefKey = 'veilid_contacts';
  static const _pausedPrefKey = 'veilid_paused_contacts';
  static const _myRecordKeyPrefKey = 'veilid_my_record_key';
  static const _myNamePrefKey = 'veilid_display_name';
  static const _contactNamesPrefKey = 'veilid_contact_names';
  // User-secret key (Veilid protected store) for the identity keypair.
  static const _myKeyPairSecretKey = 'grid_identity_keypair';

  // My display name (published to my DHT record) and the local names I've
  // assigned to contacts (address -> name).
  String? _myName;
  final Map<String, String> _contactNames = {};

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
        _contactRouteResolvedAt[address] = DateTime.now();
      } catch (e) {
        debugPrint('[Veilid] restore contact route failed for $address: $e');
      }
    }
    // Restore per-contact pause state.
    _pausedAddresses
      ..clear()
      ..addAll(prefs.getStringList(_pausedPrefKey) ?? const <String>[]);

    // Restore display name + local contact names.
    _myName = prefs.getString(_myNamePrefKey);
    final namesRaw = prefs.getString(_contactNamesPrefKey);
    if (namesRaw != null && namesRaw.isNotEmpty) {
      try {
        final map = jsonDecode(namesRaw) as Map<String, dynamic>;
        _contactNames
          ..clear()
          ..addAll(map.map((k, v) => MapEntry(k, v as String)));
      } catch (_) {}
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
      DHTSchema.dflt(oCnt: 2), // subkey 0 = route, subkey 1 = display name
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
    // Also publish the display name (subkey 1), if set.
    final name = await myName();
    if (name != null && name.isNotEmpty) {
      await context.setDHTValue(
        recordKey,
        1,
        Uint8List.fromList(utf8.encode(name)),
        options: SetDHTValueOptions(writer: kp),
      );
    }
    debugPrint('[Veilid] published route to DHT');
  }

  /// My display name (null until set). Published to my DHT record.
  Future<String?> myName() async {
    if (_myName != null) return _myName;
    final prefs = await SharedPreferences.getInstance();
    _myName = prefs.getString(_myNamePrefKey);
    return _myName;
  }

  /// Set my display name and publish it to my DHT record so contacts see it.
  Future<void> setMyName(String name) async {
    _myName = name.trim();
    final prefs = await SharedPreferences.getInstance();
    if (_myName!.isEmpty) {
      await prefs.remove(_myNamePrefKey);
    } else {
      await prefs.setString(_myNamePrefKey, _myName!);
    }
    // Publish to DHT (best-effort; it rides along with the route republish).
    try {
      await _ensureStarted();
      final recordKey = await _myRecordKeyOrCreate();
      final kp = await _keyPairOrCreate();
      final context = _routingContext!;
      await context.openDHTRecord(recordKey, writer: kp);
      await context.setDHTValue(
        recordKey,
        1,
        Uint8List.fromList(utf8.encode(_myName ?? '')),
        options: SetDHTValueOptions(writer: kp),
      );
    } catch (e) {
      debugPrint('[Veilid] publish name failed (non-fatal): $e');
    }
  }

  /// The local display name I've assigned to a contact, or null.
  String? getContactName(String address) => _contactNames[address];

  /// Rename a contact locally (their published name is only a default).
  Future<void> setContactName(String address, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _contactNames.remove(address);
    } else {
      _contactNames[address] = trimmed;
    }
    final prefs = await SharedPreferences.getInstance();
    if (_contactNames.isEmpty) {
      await prefs.remove(_contactNamesPrefKey);
    } else {
      await prefs.setString(_contactNamesPrefKey, jsonEncode(_contactNames));
    }
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

  /// Add a contact by their stable address (a DHT record key string). Their
  /// published display name is used as the default local name.
  Future<void> addContact(String address) async {
    await _ensureStarted();
    final routeId = await _importContactRoute(address);
    _contactRoutes[address] = routeId;
    _contactRouteResolvedAt[address] = DateTime.now();
    // Pull the contact's published name as a default (best-effort).
    try {
      final name = await _readContactName(address);
      if (name != null && name.isNotEmpty && !_contactNames.containsKey(address)) {
        _contactNames[address] = name;
        await _persistContactNames();
      }
    } catch (_) {}
    if (!_contactAddresses.contains(address)) {
      _contactAddresses.add(address);
      await _persistContacts();
    }
  }

  Future<String?> _readContactName(String address) async {
    final recordKey = RecordKey.fromString(address);
    final context = _routingContext!;
    await context.openDHTRecord(recordKey);
    final value = await context.getDHTValue(recordKey, 1);
    if (value == null || value.data.isEmpty) return null;
    return utf8.decode(value.data);
  }

  Future<void> _persistContactNames() async {
    final prefs = await SharedPreferences.getInstance();
    if (_contactNames.isEmpty) {
      await prefs.remove(_contactNamesPrefKey);
    } else {
      await prefs.setString(_contactNamesPrefKey, jsonEncode(_contactNames));
    }
  }

  /// Sends [lat],[lng] to every non-paused contact. Caches each contact's
  /// route for a short TTL so continuous sharing doesn't re-hit the DHT on
  /// every fix; a stale/dead route is re-resolved after the TTL.
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
      if (_pausedAddresses.contains(address)) continue;
      try {
        final routeId = await _routeFor(address);
        await context.appMessage(TargetRouteId(routeId: routeId), bytes);
      } catch (e) {
        // Clear the cache so the next send re-resolves a possibly-dead route.
        _contactRoutes.remove(address);
        _contactRouteResolvedAt.remove(address);
        debugPrint('[Veilid] sendLocation failed for $address: $e');
      }
    }
  }

  /// Cached route for [address], re-resolved every [_routeTtl].
  Future<RouteId> _routeFor(String address) async {
    final cached = _contactRoutes[address];
    final at = _contactRouteResolvedAt[address];
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _routeTtl) {
      return cached;
    }
    final routeId = await _importContactRoute(address);
    _contactRoutes[address] = routeId;
    _contactRouteResolvedAt[address] = DateTime.now();
    return routeId;
  }

  static const _routeTtl = Duration(minutes: 5);

  /// Whether sharing with [address] is paused.
  bool isContactPaused(String address) => _pausedAddresses.contains(address);

  /// Pause or resume sharing with [address].
  Future<void> setContactPaused(String address, bool paused) async {
    if (paused) {
      _pausedAddresses.add(address);
    } else {
      _pausedAddresses.remove(address);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_pausedPrefKey, _pausedAddresses.toList());
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
