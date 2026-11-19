import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:grid_frontend/services/veilid_service.dart';

/// Scans a contact's Veilid private-route blob (shown as a QR on their device)
/// and imports it as a new contact.
class VeilidScanScreen extends StatefulWidget {
  const VeilidScanScreen({super.key});

  @override
  State<VeilidScanScreen> createState() => _VeilidScanScreenState();
}

class _VeilidScanScreenState extends State<VeilidScanScreen> {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? _controller;
  bool? _permissionGranted;
  bool _handled = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _requestPermission();
  }

  Future<void> _requestPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() => _permissionGranted = status.isGranted);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onScan(Barcode barcode) async {
    if (_handled) return;
    _handled = true;
    final code = barcode.code;
    if (code == null || code.isEmpty) {
      _handled = false;
      return;
    }
    setState(() => _status = 'Importing contact…');
    try {
      await VeilidService.instance.importContact(code);
      if (!mounted) return;
      setState(() => _status = 'Contact added ✓');
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Failed: $e';
        _handled = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan contact QR')),
      body: switch (_permissionGranted) {
        null => const Center(child: CircularProgressIndicator()),
        false => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Camera permission is required to scan a contact QR.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        _ => Stack(
            children: [
              QRView(
                key: _qrKey,
                onQRViewCreated: (controller) {
                  _controller = controller;
                  controller.scannedDataStream.listen(_onScan);
                },
              ),
              if (_status != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _status!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
      },
    );
  }
}
