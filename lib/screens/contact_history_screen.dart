import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:grid_frontend/models/location_history.dart';
import 'package:grid_frontend/screens/map/grid_map_style.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/utilities/lat_lng_validation.dart';

/// A contact's recorded location history: their trail on a map plus a
/// time-ordered timeline, modeled on Life360's "Daily History" view.
class ContactHistoryScreen extends StatefulWidget {
  const ContactHistoryScreen({super.key, required this.address});

  final String address;

  @override
  State<ContactHistoryScreen> createState() => _ContactHistoryScreenState();
}

class _ContactHistoryScreenState extends State<ContactHistoryScreen> {
  MapLibreMapController? _controller;
  String? _styleJson;
  bool? _isDark;
  bool _styleLoaded = false;

  List<LocationPoint> _points = [];
  final List<Line> _lines = [];
  final List<Circle> _circles = [];
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final points = (await VeilidService.instance.contactTrail(widget.address))
        .where((p) => isFiniteLatLng(p.latitude, p.longitude))
        .toList();
    if (!mounted) return;
    setState(() => _points = points);
    if (_styleLoaded) _drawTrail();
  }

  String _short(String a) {
    final p = a.split(':');
    return p.length >= 2 ? p[1] : a;
  }

  String get _name =>
      VeilidService.instance.getContactName(widget.address) ?? _short(widget.address);

  String _fmtTime(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _drawTrail() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;

    if (_lines.isNotEmpty) {
      await controller.removeLines(List<Line>.from(_lines));
      _lines.clear();
    }
    if (_circles.isNotEmpty) {
      await controller.removeCircles(List<Circle>.from(_circles));
      _circles.clear();
    }
    if (_points.isEmpty) return;

    final coords =
        _points.map((p) => LatLng(p.latitude, p.longitude)).toList();

    if (coords.length >= 2) {
      _lines.add(await controller.addLine(LineOptions(
        geometry: coords,
        lineColor: '#00DBA4',
        lineWidth: 4.0,
        lineOpacity: 0.9,
        lineJoin: 'round',
      )));
    }
    // Only mark the two ends. One native circle per history point would mean
    // thousands of awaited platform calls on a long trail.
    if (coords.length == 1) {
      _circles.add(await controller.addCircle(CircleOptions(
        geometry: coords.first,
        circleRadius: 8.0,
        circleColor: '#00DBA4',
        circleOpacity: 1.0,
        circleStrokeWidth: 2.0,
        circleStrokeColor: '#ffffff',
      )));
    } else {
      _circles.add(await controller.addCircle(CircleOptions(
        geometry: coords.first,
        circleRadius: 5.0,
        circleColor: '#ffffff',
        circleOpacity: 1.0,
        circleStrokeWidth: 2.0,
        circleStrokeColor: '#00DBA4',
      )));
      _circles.add(await controller.addCircle(CircleOptions(
        geometry: coords.last,
        circleRadius: 8.0,
        circleColor: '#00DBA4',
        circleOpacity: 1.0,
        circleStrokeWidth: 2.0,
        circleStrokeColor: '#ffffff',
      )));
    }

    if (!_fitted) {
      _fitted = true;
      if (coords.length >= 2) {
        final lats = coords.map((c) => c.latitude).toList()..sort();
        final lngs = coords.map((c) => c.longitude).toList()..sort();
        final bounds = LatLngBounds(
          southwest: LatLng(lats.first, lngs.first),
          northeast: LatLng(lats.last, lngs.last),
        );
        await controller.moveCamera(CameraUpdate.newLatLngBounds(
          bounds,
          left: 40,
          right: 40,
          top: 120,
          bottom: 220,
        ));
      } else {
        await controller.moveCamera(CameraUpdate.newCameraPosition(
          CameraPosition(target: coords.first, zoom: 15),
        ));
      }
    }
  }

  Future<void> _centerOn(int index) async {
    final controller = _controller;
    if (controller == null || index < 0 || index >= _points.length) return;
    final p = _points[index];
    await controller.moveCamera(CameraUpdate.newCameraPosition(
      CameraPosition(target: LatLng(p.latitude, p.longitude), zoom: 16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_isDark != isDark) {
      _isDark = isDark;
      _styleJson = buildGridMapStyle(dark: isDark);
      _styleLoaded = false;
    }

    final initial = _points.isNotEmpty
        ? LatLng(_points.last.latitude, _points.last.longitude)
        : const LatLng(37.7749, -122.4194);

    return Scaffold(
      appBar: AppBar(title: Text('$_name · History')),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _styleJson!,
            initialCameraPosition:
                CameraPosition(target: initial, zoom: 14),
            onMapCreated: (controller) => _controller = controller,
            onStyleLoadedCallback: () {
              if (!mounted) return;
              _styleLoaded = true;
              _drawTrail();
            },
          ),
          // Date / summary pill near the top.
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: Center(
              child: _summaryPill(context),
            ),
          ),
          // Timeline at the bottom.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _timeline(context),
          ),
        ],
      ),
    );
  }

  Widget _summaryPill(BuildContext context) {
    final c = context.gridColors;
    final label = _points.isEmpty
        ? 'No history yet'
        : _points.length == 1
            ? _fmtTime(_points.first.timestamp)
            : '${_fmtTime(_points.first.timestamp)} – ${_fmtTime(_points.last.timestamp)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.hairline),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 14, color: c.mint),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: c.text)),
          if (_points.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text('${_points.length} pts',
                style: TextStyle(fontSize: 11, color: c.text3)),
          ],
        ],
      ),
    );
  }

  Widget _timeline(BuildContext context) {
    final c = context.gridColors;
    if (_points.isEmpty) {
      return Container(
        color: c.bg,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Text(
          'No location history recorded for $_name yet.',
          style: TextStyle(color: c.text3),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Timeline',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: c.text2)),
            const SizedBox(height: 8),
            SizedBox(
              height: 76,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _points.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final p = _points[i];
                  final isLast = i == _points.length - 1;
                  return GestureDetector(
                    onTap: () => _centerOn(i),
                    child: Container(
                      width: 92,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isLast ? c.mintFaint : c.surface2,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: isLast ? c.mint : c.hairline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(isLast ? Icons.my_location : Icons.circle,
                              size: 14,
                              color: isLast ? c.mint : c.text3),
                          const SizedBox(height: 6),
                          Text(_fmtTime(p.timestamp),
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.text)),
                          const SizedBox(height: 2),
                          Text(
                            '${p.latitude.toStringAsFixed(3)}, ${p.longitude.toStringAsFixed(3)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 9, color: c.text3),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
