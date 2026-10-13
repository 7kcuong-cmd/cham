import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Đường truyền chữ thô giữa điện thoại và web (WebSocket `/v1/link` hoặc DataChannel).
abstract class LinkTransport {
  Stream<String> get incoming;
  void send(String text);
  Future<void> close();
}

/// Kênh mã hóa đầu cuối giữa điện thoại và web: X25519 tạm thời → HKDF-SHA256 → AES-256-GCM.
/// Server/relay chỉ thấy bản mã. [shortCode] là 6 số cả hai máy hiển thị để người dùng so khớp
/// (chống kẻ chen giữa); chỉ tin kênh sau khi hai mã trùng nhau.
///
/// Xác thực bằng MÃ QR: web đưa dấu vân tay khóa công khai của nó vào QR ([localFingerprint], qua
/// [LinkPairing.qrPayload]); điện thoại quét xong truyền vào [expectedPeerFingerprint]. Khóa nhận qua server mà
/// không khớp thì kênh bị hủy, nên server (hay kẻ chen giữa) không thể giả web.
class LinkChannel {
  LinkChannel(this._t, {this.expectedPeerFingerprint}) {
    _ready.future.catchError((Object _) {});
  }

  final String? expectedPeerFingerprint;

  final LinkTransport _t;
  final X25519 _x = X25519();
  final AesGcm _aes = AesGcm.with256bits();
  final StreamController<Map<String, dynamic>> _in = StreamController<Map<String, dynamic>>.broadcast();
  final Completer<void> _ready = Completer<void>();

  SimpleKeyPair? _pair;
  SecretKey? _key;
  String? _shortCode;
  StreamSubscription<String>? _sub;
  bool _sentHello = false;
  Future<void> _chain = Future<void>.value();

  Stream<Map<String, dynamic>> get messages => _in.stream;
  Future<void> get ready => _ready.future;
  String? get shortCode => _shortCode;

  /// Dấu vân tay (base64url của SHA-256) khóa công khai của máy này; có sau [start].
  String? get localFingerprint => _localFp;
  String? _localFp;

  Future<void> start() async {
    _pair = await _x.newKeyPair();
    _localFp = await _fingerprint((await _pair!.extractPublicKey()).bytes);
    _sub = _t.incoming.listen((raw) => _chain = _chain.then((_) => _onRaw(raw)));
    await _hello();
  }

  static Future<String> _fingerprint(List<int> pk) async =>
      base64Url.encode((await Sha256().hash(pk)).bytes).replaceAll('=', '');

  /// Gọi lại khi relay báo `link.paired`: tin `hello` gửi trước lúc bên kia vào phòng đã bị bỏ.
  Future<void> hello() => _hello(force: true);

  Future<void> _hello({bool force = false}) async {
    if (_sentHello && !force) return;
    _sentHello = true;
    final pub = await _pair!.extractPublicKey();
    _t.send(jsonEncode(<String, dynamic>{'t': 'hello', 'pk': base64.encode(pub.bytes)}));
  }

  Future<void> _onRaw(String raw) async {
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (j is! Map) return;
    if (j['t'] == 'hello' && _key == null) {
      final peerPk = j['pk'];
      if (peerPk is! String) return;
      final bytes = base64.decode(peerPk);
      final want = expectedPeerFingerprint;
      if (want != null && await _fingerprint(bytes) != want) {
        if (!_ready.isCompleted) _ready.completeError(StateError('Khóa của web không khớp với mã QR'));
        _key = null;
        return;
      }
      await _hello(force: true); // bên đến sau vẫn phải gửi khóa của mình
      await _derive(bytes);
      return;
    }
    if (j['t'] == 'enc' && _key != null && j['d'] is String) {
      try {
        final box = SecretBox.fromConcatenation(base64.decode(j['d'] as String), nonceLength: 12, macLength: 16);
        final clear = utf8.decode(await _aes.decrypt(box, secretKey: _key!));
        final m = jsonDecode(clear);
        if (m is Map<String, dynamic> && !_in.isClosed) _in.add(m);
      } on Object {
        // khung hỏng/giả: bỏ
      }
    }
  }

  Future<void> _derive(List<int> peerPk) async {
    final mine = (await _pair!.extractPublicKey()).bytes;
    final secret = await _x.sharedSecretKey(
      keyPair: _pair!,
      remotePublicKey: SimplePublicKey(peerPk, type: KeyPairType.x25519),
    );
    // Sắp hai khóa công khai theo thứ tự cố định để hai bên ra cùng một thông tin.
    final a = base64.encode(mine);
    final b = base64.encode(peerPk);
    final ordered = a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
    _key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: secret, nonce: const <int>[], info: utf8.encode('cham-link-v1|$ordered'));
    final digest = await Sha256().hash(utf8.encode('cham-link-code|$ordered'));
    final n = (digest.bytes[0] << 16 | digest.bytes[1] << 8 | digest.bytes[2]) % 1000000;
    _shortCode = n.toString().padLeft(6, '0');
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> send(Map<String, dynamic> m) async {
    final key = _key;
    if (key == null) throw StateError('Kênh chưa sẵn sàng');
    final box = await _aes.encrypt(utf8.encode(jsonEncode(m)), secretKey: key);
    _t.send(jsonEncode(<String, dynamic>{'t': 'enc', 'd': base64.encode(Uint8List.fromList(box.concatenation()))}));
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _in.close();
    await _t.close();
  }
}

/// Nội dung mã QR liên kết: `cham-link:1:<code>:<vân tay khóa web>`.
class LinkPairing {
  const LinkPairing(this.code, this.fingerprint);

  final String code;
  final String fingerprint;

  String get qrPayload => 'cham-link:1:$code:$fingerprint';

  static LinkPairing? parse(String s) {
    final p = s.split(':');
    if (p.length != 4 || p[0] != 'cham-link' || p[1] != '1' || p[2].isEmpty || p[3].isEmpty) return null;
    final ok = RegExp(r'^[A-Za-z0-9_-]+$');
    if (!ok.hasMatch(p[2]) || !ok.hasMatch(p[3])) return null;
    return LinkPairing(p[2], p[3]);
  }
}
