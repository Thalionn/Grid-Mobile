import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:grid_frontend/screens/map/grid_map_style.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/services/location_manager.dart';

/// A minimal P2P map: the basemap plus a marker for each contact's latest
/// received location and one for your own position. No server.
class VeilidMapScreen extends StatefulWidget {
  const VeilidMapScreen({super.key});

  @override
  State<VeilidMapScreen> createState() => _VeilidMapScreenState();
}

class _VeilidMapScreenState extends State<VeilidMapScreen> {
  MapLibreMapController? _controller;
  String? _styleJson;
  bool? _isDark;
  bool _styleLoaded = false;

  final List<Circle> _circles = [];
  StreamSubscription<Map<String, dynamic>>? _locSub;
  bool _centeredOnMe = false;

  @override
  void initState() {
    super.initState();
    _locSub = VeilidService.instance.locationUpdates.listen((_) {
      if (mounted) _refreshMarkers();
    });
    LocationManager.instance.addListener(_onLocation);
    // The tracker's stationary interval is long (up to ~15 min), so force a
    // fresh fix on open instead of waiting for the next scheduled update.
    if (LocationManager.instance.currentLatLng == null) {
      LocationManager.instance.grabLocationAndPing();
    }
  }

  @override
  void dispose() {
    LocationManager.instance.removeListener(_onLocation);
    _locSub?.cancel();
    super.dispose();
  }

  void _onLocation() {
    if (!mounted) return;
    _refreshMarkers();
    // Center once the first fix arrives (the camera may have started on the
    // default location before GPS delivered anything).
    if (!_centeredOnMe && LocationManager.instance.currentLatLng != null) {
      _centeredOnMe = true;
      _centerOnMe();
    }
  }

  Future<void> _refreshMarkers() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;

    // Remove previous markers.
    if (_circles.isNotEmpty) {
      await controller.removeCircles(List<Circle>.from(_circles));
      _circles.clear();
    }

    // Your position (blue).
    final me = LocationManager.instance.currentLatLng;
    if (me != null) {
      _circles.add(await controller.addCircle(CircleOptions(
        geometry: LatLng(me.latitude, me.longitude),
        circleRadius: 7.0,
        circleColor: '#2563eb',
        circleOpacity: 1.0,
        circleStrokeWidth: 2.0,
        circleStrokeColor: '#ffffff',
      )));
    }

    // Contact positions (amber).
    final contacts = VeilidService.instance.contactLocations;
    for (final entry in contacts.entries) {
      final loc = entry.value;
      final lat = (loc['lat'] as num).toDouble();
      final lng = (loc['lng'] as num).toDouble();
      _circles.add(await controller.addCircle(CircleOptions(
        geometry: LatLng(lat, lng),
        circleRadius: 7.0,
        circleColor: '#f59e0b',
        circleOpacity: 1.0,
        circleStrokeWidth: 2.0,
        circleStrokeColor: '#ffffff',
      )));
    }
  }

  Future<void> _centerOnMe() async {
    final controller = _controller;
    final me = LocationManager.instance.currentLatLng;
    if (controller == null || me == null) return;
    await controller.moveCamera(CameraUpdate.newCameraPosition(
      CameraPosition(target: LatLng(me.latitude, me.longitude), zoom: 14),
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

    final me = LocationManager.instance.currentLatLng;
    final LatLng initialTarget = me != null
        ? LatLng(me.latitude, me.longitude)
        : const LatLng(37.7749, -122.4194);

    return Scaffold(
      appBar: AppBar(title: const Text('Map')),
      floatingActionButton: FloatingActionButton(
        onPressed: _centerOnMe,
        child: const Icon(Icons.my_location),
      ),
      body: MapLibreMap(
        styleString: _styleJson!,
        initialCameraPosition: CameraPosition(
          target: initialTarget,
          zoom: 14,
        ),
        onMapCreated: (controller) {
          _controller = controller;
        },
        onStyleLoadedCallback: () {
          if (!mounted) return;
          _styleLoaded = true;
          _refreshMarkers();
        },
      ),
    );
  }
}
