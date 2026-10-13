import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'ratchet.dart';

/// Mã hóa đầu cuối tin nhắn: X25519 (trao đổi khóa) → HKDF-SHA256 → AES-256-GCM.
/// Khóa riêng chỉ nằm trên máy; server chỉ giữ khóa công khai và bản mã.
class ChatCrypto {
  ChatCrypto();

  static const _info = 'cham-dm-v1';
  final X25519 _x = X25519();
  final AesGcm _aes = AesGcm.with256bits();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  SimpleKeyPair? _pair;

  /// Khóa danh tính dạng dùng cho Double Ratchet (cùng hạt giống với khóa X25519 ở trên).
  RatchetKey? identity;

  /// Khởi tạo từ hạt giống (32 byte) đã lưu, hoặc tạo mới. Trả hạt giống để lưu lại.
  Future<Uint8List> init(Uint8List? seed) async {
    final rnd = Random.secure();
    final s = seed ?? Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    _pair = await _x.newKeyPairFromSeed(s);
    identity = await RatchetKey.fromSeed(s);
    return s;
  }

  Future<String> publicKeyBase64() async {
    final pub = await _pair!.extractPublicKey();
    return base64.encode(pub.bytes);
  }

  Future<SecretKey> _shared(String peerPublicKeyB64) async {
    final remote = SimplePublicKey(base64.decode(peerPublicKeyB64), type: KeyPairType.x25519);
    final secret = await _x.sharedSecretKey(keyPair: _pair!, remotePublicKey: remote);
    return _hkdf.deriveKey(secretKey: secret, nonce: const <int>[], info: utf8.encode(_info));
  }

  /// Trả base64(nonce‖bản mã‖mac).
  Future<String> encrypt(String peerPublicKeyB64, String plain) async {
    final key = await _shared(peerPublicKeyB64);
    final box = await _aes.encrypt(utf8.encode(plain), secretKey: key);
    return base64.encode(box.concatenation());
  }

  /// Ném nếu khóa/bản mã sai.
  Future<String> decrypt(String peerPublicKeyB64, String bodyB64) async {
    final key = await _shared(peerPublicKeyB64);
    final box = SecretBox.fromConcatenation(base64.decode(bodyB64), nonceLength: 12, macLength: 16);
    final clear = await _aes.decrypt(box, secretKey: key);
    return utf8.decode(clear);
  }

  // --- gửi tệp: khóa ngẫu nhiên cho từng tệp (một lần X25519), mỗi mảnh mã hóa AES-GCM nhanh ---

  Future<SecretKey> newFileKey() => _aes.newSecretKey();

  /// Gói khóa tệp bằng khóa chung với người nhận (dùng lại đường mã hóa tin nhắn).
  Future<String> wrapFileKey(String peerPublicKeyB64, SecretKey k) async =>
      encrypt(peerPublicKeyB64, base64.encode(await k.extractBytes()));

  Future<SecretKey> unwrapFileKey(String peerPublicKeyB64, String wrapped) async =>
      SecretKey(base64.decode(await decrypt(peerPublicKeyB64, wrapped)));

  /// `aad` (mã tệp + số thứ tự mảnh) chặn đổi chỗ / lặp mảnh.
  Future<Uint8List> sealChunk(SecretKey k, List<int> plain, String aad) async {
    final box = await _aes.encrypt(plain, secretKey: k, aad: utf8.encode(aad));
    return Uint8List.fromList(box.concatenation());
  }

  Future<Uint8List> openChunk(SecretKey k, List<int> data, String aad) async {
    final box = SecretBox.fromConcatenation(data, nonceLength: 12, macLength: 16);
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: k, aad: utf8.encode(aad)));
  }
}
