import 'package:encrypt/encrypt.dart' as encrypt;

String encryptText(String text, String encryptionKey, encrypt.IV iv) {
  final key = encrypt.Key.fromBase64(encryptionKey);
  final encrypter = encrypt.Encrypter(encrypt.AES(key));
  return encrypter.encrypt(text, iv: iv).base64;
}

String decryptText(String encryptedText, String encryptionKey, String ivString) {
  final key = encrypt.Key.fromBase64(encryptionKey);
  final iv = encrypt.IV.fromBase64(ivString);
  final encrypter = encrypt.Encrypter(encrypt.AES(key));
  return encrypter.decrypt64(encryptedText, iv: iv);
}

/// Authenticated encryption (AES-256-GCM).
///
/// The legacy helpers above are unauthenticated CTR: a local attacker could
/// flip ciphertext bits and silently change a recorded trail. GCM appends a
/// 128-bit tag, so any modification fails to decrypt. Use a 12-byte IV.
String encryptTextAead(String text, String encryptionKey, encrypt.IV iv) {
  final key = encrypt.Key.fromBase64(encryptionKey);
  final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
  return encrypter.encrypt(text, iv: iv).base64;
}

String decryptTextAead(
    String encryptedText, String encryptionKey, String ivString) {
  final key = encrypt.Key.fromBase64(encryptionKey);
  final iv = encrypt.IV.fromBase64(ivString);
  final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
  return encrypter.decrypt64(encryptedText, iv: iv);
}
