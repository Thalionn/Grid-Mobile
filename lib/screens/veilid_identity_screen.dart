import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:grid_frontend/services/veilid_service.dart';

/// Shows the user's Veilid identity as a QR code + the raw string.
///
/// This is the P2P "no login" replacement for onboarding: your identity is a
/// local keypair, and the QR is how another device adds you as a contact.
class VeilidIdentityScreen extends StatefulWidget {
  const VeilidIdentityScreen({super.key});

  @override
  State<VeilidIdentityScreen> createState() => _VeilidIdentityScreenState();
}

class _VeilidIdentityScreenState extends State<VeilidIdentityScreen> {
  String? _identity;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = await VeilidService.instance.identity();
      if (mounted) setState(() => _identity = id);
    } catch (e) {
      if (mounted) setState(() => _identity = 'ERROR: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your Grid ID')),
      body: Center(
        child: _identity == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_identity!.startsWith('ERROR'))
                      const Icon(Icons.error_outline, size: 48, color: Colors.red)
                    else
                      QrImageView(data: _identity!, size: 280),
                    const SizedBox(height: 20),
                    Text(
                      _identity!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
