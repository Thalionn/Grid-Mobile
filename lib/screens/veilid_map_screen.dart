import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grid_frontend/models/location_history.dart';
import 'package:grid_frontend/screens/map/grid_map_style.dart';
import 'package:grid_frontend/screens/veilid_scan_screen.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/sharing_state_notifier.dart';
import 'package:grid_frontend/widgets/contact_detail_sheet.dart';
import 'package:grid_frontend/widgets/grid/grid_button.dart';
import 'package:grid_frontend/widgets/grid/grid_contact_row.dart';
import 'package:grid_frontend/widgets/grid/grid_mono.dart';
import 'package:grid_frontend/widgets/grid/grid_sheet.dart';
import 'package:grid_frontend/widgets/grid/grid_status_pill.dart';

/// A minimal P2P map: the basemap plus a marker for each contact's latest
/// received location, your own position, trails, a sharing pill, and a home
/// circle. No server.
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
  final List<Circle> _homeCircles = [];
  final List<Line> _lines = [];
  StreamSubscription<Map<String, dynamic>>? _locSub;
  StreamSubscription<String>? _historySub;
  bool _centeredOnMe = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _locSub = VeilidService.instance.locationUpdates.listen((_) {
      if (mounted) _refreshMarkers();
      if (mounted) _refreshTrails();
    });
    LocationManager.instance.addListener(_onLocation);
    SharingStateNotifier.instance.addListener(_onSharingChanged);
    // Refresh trails right after a point is written (avoids the read/write
    // race and the long stationary interval between location events).
    _historySub = VeilidService.instance.historyUpdates?.listen((_) {
      if (mounted) _refreshTrails();
    });
    // The tracker's stationary interval is long (up to ~15 min), so force a
    // fresh fix on open instead of waiting for the next scheduled update.
    if (LocationManager.instance.currentLatLng == null) {
      LocationManager.instance.grabLocationAndPing();
    }
  }

  @override
  void dispose() {
    LocationManager.instance.removeListener(_onLocation);
    SharingStateNotifier.instance.removeListener(_onSharingChanged);
    _locSub?.cancel();
    _historySub?.cancel();
    super.dispose();
  }

  void _onLocation() {
    if (!mounted) return;
    _refreshMarkers();
    _refreshTrails();
    // Center once the first fix arrives (the camera may have started on the
    // default location before GPS delivered anything).
    if (!_centeredOnMe && LocationManager.instance.currentLatLng != null) {
      _centeredOnMe = true;
      _centerOnMe();
    }
  }

  void _onSharingChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshMarkers() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;

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

    // Contact positions (amber), tagged with their address for tap handling.
    final contacts = VeilidService.instance.contactLocations;
    for (final entry in contacts.entries) {
      final loc = entry.value;
      final lat = (loc['lat'] as num).toDouble();
      final lng = (loc['lng'] as num).toDouble();
      _circles.add(await controller.addCircle(
        CircleOptions(
          geometry: LatLng(lat, lng),
          circleRadius: 7.0,
          circleColor: '#f59e0b',
          circleOpacity: 1.0,
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#ffffff',
        ),
        {'address': entry.key},
      ));
    }
  }

  /// Draw the persisted trails (my own and each contact's) as polylines.
  Future<void> _refreshTrails() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;

    if (_lines.isNotEmpty) {
      await controller.removeLines(List<Line>.from(_lines));
      _lines.clear();
    }

    final trails = await VeilidService.instance.loadTrails();
    for (final entry in trails.entries) {
      final points = entry.value;
      if (points.length < 2) continue;
      final coords = points
          .map((LocationPoint p) => LatLng(p.latitude, p.longitude))
          .toList();
      _lines.add(await controller.addLine(LineOptions(
        geometry: coords,
        lineColor: '#8b5cf6',
        lineWidth: 3.0,
        lineOpacity: 0.7,
      )));
    }
  }

  /// Draw the saved home location as a marker + translucent radius circle.
  Future<void> _refreshHome() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;

    if (_homeCircles.isNotEmpty) {
      await controller.removeCircles(List<Circle>.from(_homeCircles));
      _homeCircles.clear();
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('home_location');
    if (raw == null || raw.isEmpty) return;
    final parts = raw.split(',');
    if (parts.length != 2) return;
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    if (lat == null || lng == null) return;
    final radiusMeters = prefs.getDouble('home_radius') ?? 25;

    // Rough meters->pixels at the current zoom (accurate enough for a hint).
    final radiusPx = (radiusMeters / 10).clamp(12.0, 80.0);

    _homeCircles.add(await controller.addCircle(CircleOptions(
      geometry: LatLng(lat, lng),
      circleRadius: radiusPx,
      circleColor: '#22c55e',
      circleOpacity: 0.12,
    )));
    _homeCircles.add(await controller.addCircle(CircleOptions(
      geometry: LatLng(lat, lng),
      circleRadius: 6.0,
      circleColor: '#22c55e',
      circleOpacity: 1.0,
      circleStrokeWidth: 2.0,
      circleStrokeColor: '#ffffff',
    )));
  }

  void _onCircleTapped(Circle circle) {
    final address = circle.data?['address'] as String?;
    if (address == null) return;
    _openContact(address);
  }

  void _openContact(String address) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContactDetailSheet(address: address),
    ).then((_) => setState(() {}));
  }

  void _openContactSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _MapContactSheet(),
    ).then((_) => setState(() {}));
  }

  Future<void> _sendLocation() async {
    setState(() => _sending = true);
    try {
      if (LocationManager.instance.currentLatLng == null) {
        await LocationManager.instance.grabLocationAndPing();
      }
      final pos = LocationManager.instance.currentLatLng;
      if (pos == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No location fix yet — waiting for GPS.')),
          );
        }
        return;
      }
      await VeilidService.instance.sendLocation(pos.latitude, pos.longitude);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Shared ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)} '
              'to ${VeilidService.instance.contactAddresses.length} contact(s)',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
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

  Widget _buildSharingPill() {
    final paused = SharingStateNotifier.instance.isPaused;
    final count = VeilidService.instance.contactAddresses.length;
    final c = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _openContactSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: paused ? c.surfaceContainerHighest : c.primary,
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(paused ? Icons.pause_circle_outline : Icons.circle,
                size: 14,
                color: paused ? c.onSurfaceVariant : c.onPrimary),
            const SizedBox(width: 8),
            Text(
              paused ? 'Paused' : 'Sharing · $count contact${count == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: paused ? c.onSurfaceVariant : c.onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
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
      appBar: AppBar(
        title: const Text('Map'),
        actions: [
          IconButton(
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share_location),
            tooltip: 'Share my location',
            onPressed: _sending ? null : _sendLocation,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _centerOnMe,
        child: const Icon(Icons.my_location),
      ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _styleJson!,
            initialCameraPosition: CameraPosition(
              target: initialTarget,
              zoom: 14,
            ),
            onMapCreated: (controller) {
              _controller = controller;
              controller.onCircleTapped.add(_onCircleTapped);
            },
            onStyleLoadedCallback: () {
              if (!mounted) return;
              _styleLoaded = true;
              _refreshMarkers();
              _refreshTrails();
              _refreshHome();
            },
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(child: _buildSharingPill()),
          ),
        ],
      ),
    );
  }
}

/// Slide-up contact sheet over the map: list + add.
class _MapContactSheet extends StatefulWidget {
  const _MapContactSheet();

  @override
  State<_MapContactSheet> createState() => _MapContactSheetState();
}

class _MapContactSheetState extends State<_MapContactSheet> {
  String _short(String address) {
    final parts = address.split(':');
    return parts.length >= 2 ? parts[1] : address;
  }

  String _displayName(String address) {
    return VeilidService.instance.getContactName(address) ?? _short(address);
  }

  Future<void> _openScan() async {
    Navigator.of(context).pop();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VeilidScanScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = VeilidService.instance.contactAddresses;
    final paused = SharingStateNotifier.instance.isPaused;
    return GridSheetContainer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridSheetHeader(
              title: 'Contacts',
              subtitle: paused ? 'Sharing paused' : 'Sharing live',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 12),
            GridButton(
              label: 'Add contact',
              icon: Icons.qr_code_scanner,
              style: GridButtonStyle.secondary,
              onPressed: _openScan,
            ),
            const SizedBox(height: 8),
            if (contacts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No contacts yet — scan a friend\'s QR to link.',
                    style: Theme.of(context).textTheme.bodySmall),
              )
            else
              for (final address in contacts)
                GridContactRow(
                  name: _displayName(address),
                  handle: address,
                  statusLabel:
                      VeilidService.instance.isContactPaused(address)
                          ? 'PAUSED'
                          : 'LINKED',
                  statusKind: VeilidService.instance.isContactPaused(address)
                      ? GridStatusKind.paused
                      : GridStatusKind.live,
                  onTap: () {
                    Navigator.of(context).pop();
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => ContactDetailSheet(address: address),
                    );
                  },
                ),
          ],
        ),
      ),
    );
  }
}
