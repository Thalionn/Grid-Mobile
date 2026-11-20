import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A QR code rendered in the Grid mint green on a white quiet zone.
///
/// The plain black-modules-on-transparent QR is near-invisible against the
/// dark app background and hard to scan; this gives a bright, on-theme code
/// with the light background scanners expect.
class GridAddressQr extends StatelessWidget {
  const GridAddressQr({super.key, required this.data, this.size = 160});

  final String data;
  final double size;

  // A slightly deeper mint than the UI accent — the accent (0x00DBA4) is a
  // touch light on white, which QR readers can struggle with.
  static const Color _module = Color(0xFF00A87C);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: QrImageView(
        data: data,
        size: size,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: _module,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: _module,
        ),
      ),
    );
  }
}
