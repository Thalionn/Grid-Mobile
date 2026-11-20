class LocationPoint {
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final String? accuracy;

  LocationPoint({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
  });

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'timestamp': timestamp.toIso8601String(),
    if (accuracy != null) 'accuracy': accuracy,
  };

  factory LocationPoint.fromJson(Map<String, dynamic> json) => LocationPoint(
    latitude: json['latitude'] as double,
    longitude: json['longitude'] as double,
    timestamp: DateTime.parse(json['timestamp'] as String),
    accuracy: json['accuracy'] as String?,
  );
}

class LocationHistory {
  /// The Veilid address (DHT record key) this trail belongs to.
  final String address;
  final List<LocationPoint> points;
  final DateTime lastUpdated;

  LocationHistory({
    required this.address,
    required this.points,
    required this.lastUpdated,
  });

  Map<String, dynamic> toJson() => {
    'address': address,
    'points': points.map((p) => p.toJson()).toList(),
    'lastUpdated': lastUpdated.toIso8601String(),
  };

  factory LocationHistory.fromJson(Map<String, dynamic> json) => LocationHistory(
    address: json['address'] as String,
    points: (json['points'] as List)
        .map((p) => LocationPoint.fromJson(p as Map<String, dynamic>))
        .toList(),
    lastUpdated: DateTime.parse(json['lastUpdated'] as String),
  );
}

class LocationHistoryConfig {
  static const int maxDaysToStore = 7;
  // Denser trail (was 180s / 50m): record roughly every 20s when moving
  // (below the tracker's 30s broadcast throttle), with a 15m floor to stay
  // above GPS jitter when stationary.
  static const int minSecondsBetweenPoints = 20;
  static const double minDistanceMeters = 15.0;

  // The point cap has to coexist with a 7-day retention window. At 20 s a
  // continuously-moving day is ~4 320 points, so the last day is kept as
  // recorded and everything older is decimated. Budget: 4 320 + 6 days at one
  // point per 6 min (1 440) = 5 760 < 6 000.
  static const Duration denseWindow = Duration(hours: 24);
  static const Duration coarseInterval = Duration(minutes: 6);
  static const int maxPointsPerAddress = 6000;
}

/// Downsample a trail so a full [LocationHistoryConfig.maxDaysToStore] window
/// fits in [LocationHistoryConfig.maxPointsPerAddress]:
///
/// - points from the last [LocationHistoryConfig.denseWindow] are kept exactly
///   as recorded (the part users actually scrub through);
/// - older points collapse to one per [LocationHistoryConfig.coarseInterval],
///   which still shows the shape of the day before yesterday at a fraction of
///   the size.
///
/// Expects [points] sorted oldest-first (the repository always appends).
List<LocationPoint> compactHistoryPoints(
  List<LocationPoint> points,
  DateTime now, {
  Duration denseWindow = LocationHistoryConfig.denseWindow,
  Duration coarseInterval = LocationHistoryConfig.coarseInterval,
}) {
  final denseCutoff = now.subtract(denseWindow);
  final out = <LocationPoint>[];
  LocationPoint? lastCoarse;
  for (final point in points) {
    if (point.timestamp.isAfter(denseCutoff)) {
      out.add(point);
      lastCoarse = null;
      continue;
    }
    if (lastCoarse == null ||
        point.timestamp.difference(lastCoarse.timestamp) >= coarseInterval) {
      out.add(point);
      lastCoarse = point;
    }
  }
  return out;
}