import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

/// Minimal Veilid integration for the P2P spike.
///
/// Right now this just proves the Veilid core initializes on-device and
/// exposes a stable, QR-encodable identity (a public key string). It is
/// intentionally small: the real contact/location layers come later.
class VeilidService {
  VeilidService._();
  static final VeilidService instance = VeilidService._();

  bool _started = false;
  String? _identity;

  Future<void> _ensureStarted() async {
    if (_started) return;

    const platformConfig = VeilidFFIConfig(
      logging: VeilidFFIConfigLogging(
        terminal: VeilidFFIConfigLoggingTerminal(
          enabled: false,
          level: VeilidConfigLogLevel.debug,
        ),
        api: VeilidFFIConfigLoggingApi(
          enabled: true,
          level: VeilidConfigLogLevel.info,
        ),
      ),
    );
    Veilid.instance.initializeVeilidCore(platformConfig.toJson());

    final config = await getDefaultVeilidConfig(
      isWeb: kIsWeb,
      programName: 'Grid',
    );
    // The Android Keystore-backed secure store can be unavailable (locked or
    // unsupported), and the default config refuses to fall back. Allow the
    // disk-based fallback so the node can still boot.
    final patched = config.copyWith(
      protectedStore: config.protectedStore.copyWith(
        allowInsecureFallback: true,
      ),
    );
    await Veilid.instance.startupVeilidCore(patched);
    await Veilid.instance.attach();

    _started = true;
  }

  /// Returns a stable identity string (a Veilid public key) suitable for
  /// rendering into a QR code. Generates one on first use.
  Future<String> identity() async {
    if (_identity != null) return _identity!;
    await _ensureStarted();
    final keypair = await Veilid.instance.generateKeyPair(cryptoKindVLD0);
    _identity = keypair.key.toString();
    return _identity!;
  }
}
