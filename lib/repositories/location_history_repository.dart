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
class LocationHistoryRepository {
  final DatabaseService _databaseService;
  final StreamController<String> _historyUpdatesController = StreamController<String>.broadcast();

  LocationHistoryRepository(this._databaseService);

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

  Future<void> addLocationPoint(String address, double latitude, double longitude) async {
    final db = await _databaseService.database;
    final encryptionKey = await _databaseService.getEncryptionKey();
    final now = DateTime.now();

    // Get existing history
    LocationHistory? existingHistory = await getLocationHistory(address);
    List<LocationPoint> points = existingHistory?.points ?? [];

    // Check if we should add this point
    if (points.isNotEmpty) {
      final lastPoint = points.last;
      final timeDiff = now.difference(lastPoint.timestamp).inSeconds;
      
      // Skip if too soon
      if (timeDiff < LocationHistoryConfig.minSecondsBetweenPoints) {
        return;
      }

      // Check distance
      final distance = Geolocator.distanceBetween(
        lastPoint.latitude,
        lastPoint.longitude,
        latitude,
        longitude,
      );

      // Skip if too close
      if (distance < LocationHistoryConfig.minDistanceMeters) {
        return;
      }
    }

    // Add new point
    points.add(LocationPoint(
      latitude: latitude,
      longitude: longitude,
      timestamp: now,
    ));

    // Remove old points (older than 7 days)
    final cutoffDate = now.subtract(Duration(days: LocationHistoryConfig.maxDaysToStore));
    points = points.where((p) => p.timestamp.isAfter(cutoffDate)).toList();

    // Limit total points
    if (points.length > LocationHistoryConfig.maxPointsPerAddress) {
      points = points.sublist(points.length - LocationHistoryConfig.maxPointsPerAddress);
    }

    // Save updated history
    await _saveLocationHistory(address, points, now, encryptionKey);
    
    // Notify listeners
    _historyUpdatesController.add(address);
  }

  Future<void> _saveLocationHistory(
    String address,
    List<LocationPoint> points,
    DateTime lastUpdated,
    String encryptionKey,
  ) async {
    final db = await _databaseService.database;
    
    // Convert points to JSON
    final pointsJson = jsonEncode(points.map((p) => p.toJson()).toList());
    
    // Generate IV and encrypt the data
    final iv = encrypt.IV.fromSecureRandom(16);
    final encryptedData = encryptText(pointsJson, encryptionKey, iv);
    
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
    final db = await _databaseService.database;
    final encryptionKey = await _databaseService.getEncryptionKey();
    
    final results = await db.query(
      'LocationHistory',
      where: 'address = ?',
      whereArgs: [address],
      limit: 1,
    );

    if (results.isEmpty) {
      return null;
    }

    final row = results.first;
    
    // Decrypt the data
    final decrypted = decryptText(
      row['pointsData'] as String,
      encryptionKey,
      row['iv'] as String,
    );

    // Parse JSON
    final pointsList = (jsonDecode(decrypted) as List)
        .map((json) => LocationPoint.fromJson(json))
        .toList();

    return LocationHistory(
      address: address,
      points: pointsList,
      lastUpdated: DateTime.parse(row['lastUpdated'] as String),
    );
  }

  Future<Map<String, LocationHistory>> getLocationHistoriesForAddresses(List<String> addresses) async {
    final db = await _databaseService.database;
    final encryptionKey = await _databaseService.getEncryptionKey();
    
    if (addresses.isEmpty) return {};

    final placeholders = List.filled(addresses.length, '?').join(',');
    final results = await db.rawQuery(
      'SELECT * FROM LocationHistory WHERE address IN ($placeholders)',
      addresses,
    );

    final historyMap = <String, LocationHistory>{};

    for (final row in results) {
      final address = row['address'] as String;
      
      // Decrypt the data
      final decrypted = decryptText(
        row['pointsData'] as String,
        encryptionKey,
        row['iv'] as String,
      );

      // Parse JSON
      final pointsList = (jsonDecode(decrypted) as List)
          .map((json) => LocationPoint.fromJson(json))
          .toList();

      historyMap[address] = LocationHistory(
        address: address,
        points: pointsList,
        lastUpdated: DateTime.parse(row['lastUpdated'] as String),
      );
    }

    return historyMap;
  }

  Future<void> deleteAddressHistory(String address) async {
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
  }
}
