import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/screens/veilid_scan_screen.dart';

/// The P2P "home": your shareable contact QR, scan-to-add, and the location
/// send/receive proof. No login, no server.
class VeilidIdentityScreen extends StatefulWidget {
  const VeilidIdentityScreen({super.key});

  @override
  State<VeilidIdentityScreen> createState() => _VeilidIdentityScreenState();
}

class _VeilidIdentityScreenState extends State<VeilidIdentityScreen> {
  String? _identity;
  String? _shareBlob;
  String? _shareError;
  bool _loadingShare = false;
  bool _sending = false;

  final List<Map<String, dynamic>> _received = [];
  StreamSubscription<Map<String, dynamic>>? _locSub;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
    _loadShareBlob();
    _locSub = VeilidService.instance.locationUpdates.listen((loc) {
      if (mounted) setState(() => _received.add(loc));
    });
  }

  @override
  void dispose() {
    _locSub?.cancel();
    super.dispose();
  }

  Future<void> _loadIdentity() async {
    try {
      final id = await VeilidService.instance.identity();
      if (mounted) setState(() => _identity = id);
    } catch (e) {
      if (mounted) setState(() => _shareError = 'Identity error: $e');
    }
  }

  Future<void> _loadShareBlob() async {
    setState(() {
      _loadingShare = true;
      _shareError = null;
    });
    try {
      final blob = await VeilidService.instance.shareRouteBlobB64();
      if (mounted) setState(() => _shareBlob = blob);
    } catch (e) {
      if (mounted) setState(() => _shareError = '$e');
    } finally {
      if (mounted) setState(() => _loadingShare = false);
    }
  }

  Future<void> _openScan() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const VeilidScanScreen()),
    );
    if (added == true && mounted) setState(() {});
  }

  Future<void> _sendLocation() async {
    setState(() => _sending = true);
    try {
      // Fetch a fresh fix if we don't have one yet.
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
      await VeilidService.instance.sendLocation(
        pos.latitude,
        pos.longitude,
        accuracy: 12.0,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sent ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)} '
              'to ${VeilidService.instance.contactRouteIds.length} contact(s)',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contacts = VeilidService.instance.contactRouteIds;

    return Scaffold(
      appBar: AppBar(title: const Text('Your Grid ID')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: _loadingShare
                ? const CircularProgressIndicator()
                : _shareBlob != null
                    ? Column(
                        children: [
                          QrImageView(data: _shareBlob!, size: 260),
                          const SizedBox(height: 8),
                          Text('Scan this to add you',
                              style: theme.textTheme.bodySmall),
                        ],
                      )
                    : Column(
                        children: [
                          const Icon(Icons.wifi_off, size: 40, color: Colors.orange),
                          const SizedBox(height: 8),
                          if (_shareError != null)
                            Text(
                              _shareError!,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: Colors.orange),
                            ),
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            onPressed: _loadShareBlob,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
          ),
          const SizedBox(height: 8),
          if (_identity != null)
            Text(
              _identity!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _openScan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _sending ? null : _sendLocation,
                  icon: const Icon(Icons.my_location),
                  label: const Text('Send location'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Text('Contacts (${contacts.length})', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (contacts.isEmpty)
            Text('No contacts yet', style: theme.textTheme.bodySmall)
          else
            for (final id in contacts)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ),
          const SizedBox(height: 24),
          Text('Received locations', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_received.isEmpty)
            Text('None yet', style: theme.textTheme.bodySmall)
          else
            for (final loc in _received.reversed)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.location_on_outlined),
                title: Text(
                  '${loc['lat']?.toStringAsFixed(5)}, ${loc['lng']?.toStringAsFixed(5)}',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  'from ${loc['sender'] ?? loc['routeId'] ?? 'unknown'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
        ],
      ),
    );
  }
}
