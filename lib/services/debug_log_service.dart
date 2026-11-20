import 'package:flutter/foundation.dart';

/// Local-only diagnostic logger.
///
/// This used to POST structured events (including precise coordinates) over
/// plain HTTP to a hard-coded endpoint. That path is gone: in a private
/// location app, no telemetry should leave the device at all. Logging now goes
/// to the local debug console only, and only in debug builds.
class DebugLogService {
  static final instance = DebugLogService._();
  DebugLogService._();

  /// Retained for callers that check whether diagnostics are on. Always false:
  /// there is no remote sink.
  bool get enabled => false;

  /// No remote endpoint exists.
  String? get endpoint => null;

  /// Local-only log line. Never performs I/O and never throws.
  void log(String type, Map<String, dynamic> data) {
    if (!kDebugMode) return;
    try {
      debugPrint('[diag] $type $data');
    } catch (_) {
      // Diagnostics must never affect the app.
    }
  }
}
