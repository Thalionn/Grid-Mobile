import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:grid_frontend/screens/contact_history_screen.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/utilities/time_ago_formatter.dart';
import 'package:grid_frontend/widgets/grid/grid_mono.dart';
import 'package:grid_frontend/widgets/grid/grid_sheet.dart';

/// Bottom sheet showing a contact's details and the per-contact sharing toggle.
/// Shared by the Contacts list and the map's marker tap.
class ContactDetailSheet extends StatefulWidget {
  const ContactDetailSheet({super.key, required this.address});

  final String address;

  @override
  State<ContactDetailSheet> createState() => _ContactDetailSheetState();
}

class _ContactDetailSheetState extends State<ContactDetailSheet> {
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _paused = VeilidService.instance.isContactPaused(widget.address);
  }

  String get _short {
    final parts = widget.address.split(':');
    return parts.length >= 2 ? parts[1] : widget.address;
  }

  String get _name =>
      VeilidService.instance.getContactName(widget.address) ?? _short;

  Future<void> _editName() async {
    final controller =
        TextEditingController(text: VeilidService.instance.getContactName(widget.address) ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null) return;
    await VeilidService.instance.setContactName(widget.address, name);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loc = VeilidService.instance.contactLocations[widget.address];

    String? lastSeen;
    String? distance;
    if (loc != null) {
      final ts = loc['ts'];
      lastSeen = ts is DateTime ? ts.toIso8601String() : null;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      final me = LocationManager.instance.currentLatLng;
      if (lat != null && lng != null && me != null) {
        final m =
            Geolocator.distanceBetween(me.latitude, me.longitude, lat, lng);
        distance = m < 1000
            ? '${m.round()} m'
            : '${(m / 1000).toStringAsFixed(1)} km';
      }
    }

    return GridSheetContainer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridSheetHeader(
              title: _name,
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: GridMono(widget.address,
                      size: 10,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      uppercase: false),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Edit name',
                  onPressed: _editName,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _infoTile(context, 'Last seen',
                    lastSeen == null ? '—' : TimeAgoFormatter.format(lastSeen)),
                const SizedBox(width: 16),
                _infoTile(context, 'Distance', distance ?? '—'),
              ],
            ),
            const SizedBox(height: 4),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timeline),
              title: const Text('View location history'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final nav = Navigator.of(context);
                nav.pop();
                nav.push(MaterialPageRoute(
                  builder: (_) => ContactHistoryScreen(address: widget.address),
                ));
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Share my location'),
              subtitle: const Text(
                  'Stop or resume sharing your live location with this contact'),
              value: !_paused,
              onChanged: (v) async {
                setState(() => _paused = !v);
                await VeilidService.instance
                    .setContactPaused(widget.address, !v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoTile(BuildContext context, String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
