import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/screens/veilid_scan_screen.dart';

/// The P2P "home": shows your shareable contact QR (a Veilid private-route
/// blob) and lets you scan someone else's to add them. No login, no server.
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

  @override
  void initState() {
    super.initState();
    _loadIdentity();
    _loadShareBlob();
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
          FilledButton.icon(
            onPressed: _openScan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan to add contact'),
          ),
          const SizedBox(height: 32),
          Text('Contacts', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (contacts.isEmpty)
            Text('No contacts yet', style: theme.textTheme.bodySmall)
          else
            for (final id in contacts)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(
                  id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
        ],
      ),
    );
  }
}
