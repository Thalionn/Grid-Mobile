import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:grid_frontend/models/location_history.dart';
import 'package:grid_frontend/services/database_service.dart';
import 'package:grid_frontend/utilities/encryption_utils.dart';
import 'package:geolocator/geolocator.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

/// Persists the device-local location trail (history) for a Veilid address.
///
/// Each address (a contact, or the local user) has one encrypted history of
/// [LocationPoint]s. Keyed by the address string rather than the Matrix user
/// id it used before the P2P rebuild.
///
/// Storage notes:
/// - Points are sealed with AES-GCM (authenticated), so tampering is detected
///   instead of silently producing a forged trail. Rows written by older
///   builds use unauthenticated AES-CTR and are still readable; they are
///   transparently re-sealed on the next write.
/// - The decrypted trail is cached in memory, which removes a decrypt of the
///   whole history from every single point append.
/// - Writes per address are serialized, so two fixes arriving together cannot
///   overwrite each other.
class LocationHistoryRepository {
  final DatabaseService _databaseService;
  final StreamController<String> _historyUpdatesController = StreamController<String>.broadcast();

  LocationHistoryRepository(this._databaseService);

  /// Format marker for authenticated rows.
  static const String _aeadPrefix = 'v2:';

  /// Decrypted trails, keyed by address.
  final Map<String, LocationHistory> _cache = {};

  /// Per-address write chain so concurrent appends are not lost.
  final Map<String, Future<void>> _writes = {};

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE LocationHistory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        address TEXT NOT NULL,
        pointsData TEXT NOT NULL,
        lastUpdated TEXT NOT NULL,
        iv TEXT NOT NULL,
        UNIQUE(address) ON CONFLICT REPLACE
      );
    ''');

    await db.execute('''
      CREATE INDEX idx_location_history_address ON LocationHistory(address);
    ''');
  }

  Stream<String> get historyUpdates => _historyUpdatesController.stream;

  /// Append a fix, throttled by [LocationHistoryConfig]. Concurrent calls for
  /// the same address are queued behind each other.
  Future<void> addLocationPoint(String address, double latitude, double longitude) {
    final previous = _writes[address] ?? Future<void>.value();
    final next = previous.then(
      (_) => _addLocationPoint(address, latitude, longitude),
    );
    _writes[address] = next.catchError((Object _) {});
    return next;
  }

  Future<void> _addLocationPoint(
      String address, double latitude, double longitude) async {
    final now = DateTime.now();

    // Copy: the cached list must not be mutated in place.
    final existing = await getLocationHistory(address);
    var points = existing == null ? <LocationPoint>[] : List<LocationPoint>.of(existing.points);

    if (points.isNotEmpty) {
      final lastPoint = points.last;
      final timeDiff = now.difference(lastPoint.timestamp).inSeconds;

      // Skip if too soon.
      if (timeDiff < LocationHistoryConfig.minSecondsBetweenPoints) return;

      final distance = Geolocator.distanceBetween(
        lastPoint.latitude,
        lastPoint.longitude,
        latitude,
        longitude,
      );

      // Skip if too close.
      if (distance < LocationHistoryConfig.minDistanceMeters) return;
    }

    points.add(LocationPoint(
      latitude: latitude,
      longitude: longitude,
      timestamp: now,
    ));

    // Drop points older than the retention window.
    final cutoffDate =
        now.subtract(Duration(days: LocationHistoryConfig.maxDaysToStore));
    points = points.where((p) => p.timestamp.isAfter(cutoffDate)).toList();

    // Cap the total so a fast fix rate cannot grow the blob without bound.
    if (points.length > LocationHistoryConfig.maxPointsPerAddress) {
      points = points.sublist(
          points.length - LocationHistoryConfig.maxPointsPerAddress);
    }

    final encryptionKey = await _databaseService.getEncryptionKey();
    await _saveLocationHistory(address, points, now, encryptionKey);

    _cache[address] = LocationHistory(
      address: address,
      points: points,
      lastUpdated: now,
    );

    _historyUpdatesController.add(address);
  }

  Future<void> _saveLocationHistory(
    String address,
    List<LocationPoint> points,
    DateTime lastUpdated,
    String encryptionKey,
  ) async {
    final db = await _databaseService.database;

    final pointsJson = jsonEncode(points.map((p) => p.toJson()).toList());

    // AES-GCM: 12-byte nonce, authentication tag appended by the cipher.
    final iv = encrypt.IV.fromSecureRandom(12);
    final encryptedData = '$_aeadPrefix${encryptTextAead(pointsJson, encryptionKey, iv)}';

    await db.insert(
      'LocationHistory',
      {
        'address': address,
        'pointsData': encryptedData,
        'iv': iv.base64,
        'lastUpdated': lastUpdated.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<LocationHistory?> getLocationHistory(String address) async {
    final cached = _cache[address];
    if (cached != null) {
      return LocationHistory(
        address: cached.address,
        points: List<LocationPoint>.of(cached.points),
        lastUpdated: cached.lastUpdated,
      );
    }

    final db = await _databaseService.database;
    final encryptionKey = await _databaseService.getEncryptionKey();

    final results = await db.query(
      'LocationHistory',
      where: 'address = ?',
      whereArgs: [address],
      limit: 1,
    );

    if (results.isEmpty) return null;

    final history = _decodeRow(results.first, encryptionKey);
    if (history == null) return null;
    _cache[address] = history;
    return LocationHistory(
      address: history.address,
      points: List<LocationPoint>.of(history.points),
      lastUpdated: history.lastUpdated,
    );
  }

  /// Decrypt and parse one row. Returns null when the row is corrupt or fails
  /// its authentication tag (never throw: one bad row must not break the map).
  LocationHistory? _decodeRow(Map<String, Object?> row, String encryptionKey) {
    final address = row['address'] as String;
    try {
      final stored = row['pointsData'] as String;
      final iv = row['iv'] as String;
      final decrypted = stored.startsWith(_aeadPrefix)
          ? decryptTextAead(stored.substring(_aeadPrefix.length), encryptionKey, iv)
          : decryptText(stored, encryptionKey, iv);

      final pointsList = (jsonDecode(decrypted) as List)
          .map((json) => LocationPoint.fromJson(json))
          .toList();

      return LocationHistory(
        address: address,
        points: pointsList,
        lastUpdated: DateTime.parse(row['lastUpdated'] as String),
      );
    } catch (_) {
      // Corrupt or tampered row: drop it rather than crash.
      _cache.remove(address);
      return null;
    }
  }

  Future<Map<String, LocationHistory>> getLocationHistoriesForAddresses(List<String> addresses) async {
    if (addresses.isEmpty) return {};

    final historyMap = <String, LocationHistory>{};
    final missing = <String>[];

    for (final address in addresses) {
      final cached = _cache[address];
      if (cached != null) {
        historyMap[address] = LocationHistory(
          address: address,
          points: List<LocationPoint>.of(cached.points),
          lastUpdated: cached.lastUpdated,
        );
      } else {
        missing.add(address);
      }
    }
    if (missing.isEmpty) return historyMap;

    final db = await _databaseService.database;
    final encryptionKey = await _databaseService.getEncryptionKey();

    final placeholders = List.filled(missing.length, '?').join(',');
    final results = await db.rawQuery(
      'SELECT * FROM LocationHistory WHERE address IN ($placeholders)',
      missing,
    );

    for (final row in results) {
      final history = _decodeRow(row, encryptionKey);
      if (history == null) continue;
      _cache[history.address] = history;
      historyMap[history.address] = LocationHistory(
        address: history.address,
        points: List<LocationPoint>.of(history.points),
        lastUpdated: history.lastUpdated,
      );
    }

    return historyMap;
  }

  Future<void> deleteAddressHistory(String address) async {
    _cache.remove(address);
    _writes.remove(address);
    final db = await _databaseService.database;
    await db.delete(
      'LocationHistory',
      where: 'address = ?',
      whereArgs: [address],
    );
  }

  Future<void> cleanupOldHistories() async {
    final db = await _databaseService.database;
    final cutoffDate = DateTime.now().subtract(Duration(days: LocationHistoryConfig.maxDaysToStore));

    await db.delete(
      'LocationHistory',
      where: 'lastUpdated < ?',
      whereArgs: [cutoffDate.toIso8601String()],
    );
    _cache.removeWhere((_, h) => h.lastUpdated.isBefore(cutoffDate));
  }
}
