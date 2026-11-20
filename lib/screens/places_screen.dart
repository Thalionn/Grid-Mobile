import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/utilities/lat_lng_validation.dart';
import 'package:grid_frontend/widgets/grid/grid_button.dart';

/// "Places" tab: saved places (who's currently there) + movement alerts,
/// modeled on Life360.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  StreamSubscription<MovementAlert>? _alertSub;
  StreamSubscription<Map<String, dynamic>>? _locSub;
  DateTime _lastLocationRebuild = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    PlacesService.instance.load();
    _alertSub = VeilidService.instance.movementAlerts.listen((_) {
      if (mounted) setState(() {});
    });
    _locSub = VeilidService.instance.locationUpdates.listen((_) {
      // Presence only needs occasional refresh; don't rebuild the whole list on
      // every incoming fix.
      final now = DateTime.now();
      if (!mounted || now.difference(_lastLocationRebuild).inSeconds < 5) return;
      _lastLocationRebuild = now;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _locSub?.cancel();
    super.dispose();
  }

  String _name(String address) {
    final n = VeilidService.instance.getContactName(address);
    if (n != null && n.isNotEmpty) return n;
    final p = address.split(':');
    return p.length >= 2 ? p[1] : address;
  }

  /// Contact addresses currently within [place]'s radius.
  List<String> _whoIsHere(Place place) {
    final result = <String>[];
    VeilidService.instance.contactLocations.forEach((address, loc) {
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) return;
      final m = Geolocator.distanceBetween(
          place.latitude, place.longitude, lat, lng);
      if (m <= place.radiusMeters) result.add(address);
    });
    return result;
  }

  Future<void> _addPlace() async {
    final me = LocationManager.instance.currentLatLng;
    if (me == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No location fix yet — move a little and retry.')),
        );
      }
      return;
    }
    final controller = TextEditingController();
    double radius = 150;
    final result = await showDialog<(String, double)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add place'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Home, Work, Gym…',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Radius'),
                  Expanded(
                    child: Slider(
                      value: radius,
                      min: 50,
                      max: 500,
                      divisions: 9,
                      label: '${radius.round()} m',
                      onChanged: (v) => setDialogState(() => radius = v),
                    ),
                  ),
                  Text('${radius.round()} m'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop((controller.text, radius)),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final (name, r) = result;
    if (name.trim().isEmpty) return;
    await PlacesService.instance.add(Place(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      latitude: me.latitude,
      longitude: me.longitude,
      radiusMeters: r,
    ));
    if (mounted) setState(() {});
  }

  Future<void> _deletePlace(Place place) async {
    await PlacesService.instance.remove(place.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gridColors;
    final places = PlacesService.instance.places;
    final alerts = VeilidService.instance.recentAlerts;

    return Scaffold(
      appBar: AppBar(title: const Text('Places')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _section(c, 'Saved places'),
          if (places.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text('No places yet — add Home, Work, or anywhere.',
                  style: TextStyle(color: c.text3, fontSize: 13)),
            )
          else
            for (final p in places) _placeTile(context, p),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: GridButton(
              label: 'Add place at my location',
              icon: Icons.add_location_alt_outlined,
              style: GridButtonStyle.secondary,
              onPressed: _addPlace,
            ),
          ),
          const SizedBox(height: 16),
          _section(c, 'Movement alerts'),
          if (alerts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text('No movement yet.', style: TextStyle(color: c.text3, fontSize: 13)),
            )
          else
            for (final a in alerts.take(20)) _alertTile(context, a),
        ],
      ),
    );
  }

  Widget _placeTile(BuildContext context, Place place) {
    final c = context.gridColors;
    final here = _whoIsHere(place);
    final who = here.isEmpty
        ? 'Nobody here'
        : here.map(_name).join(', ');
    return ListTile(
      leading: Icon(Icons.place_outlined, color: c.mint),
      title: Text(place.name),
      subtitle: Text('${who} · within ${place.radiusMeters.round()} m'),
      isThreeLine: false,
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        tooltip: 'Remove place',
        onPressed: () => _deletePlace(place),
      ),
    );
  }

  Widget _alertTile(BuildContext context, MovementAlert a) {
    final c = context.gridColors;
    final ago = _timeAgo(a.at);
    return ListTile(
      dense: true,
      leading: Icon(
        a.moving ? Icons.directions_run : Icons.pause_circle_outline,
        color: a.moving ? c.mint : c.text3,
        size: 20,
      ),
      title: Text('${_name(a.address)} ${a.moving ? 'started moving' : 'stopped'}'),
      subtitle: Text(ago, style: TextStyle(fontSize: 11, color: c.text3)),
    );
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Widget _section(GridColors c, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Text(label.toUpperCase(),
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: c.mint)),
    );
  }
}
