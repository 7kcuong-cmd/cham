import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Double Ratchet cho tin nhắn Chạm. Cài đặt này PHẢI cho kết quả giống hệt bản tham chiếu Node
/// (tools/ratchet-ref/ratchet.mjs); test/ratchet_vectors_test.dart kiểm bằng tools/ratchet-ref/vectors.json.
/// CHƯA CHẠY TRÊN MÁY THẬT: tạo ra từ mô tả thuật toán đã kiểm bằng Node, chưa biên dịch bằng Dart.
///
/// Thiết kế: khóa danh tính X25519 hiện có làm gốc (không cần prekey trên server). Mỗi cặp có tối đa hai phiên:
/// `mine` (tôi khởi tạo) và `theirs` (họ khởi tạo). Bên có khóa công khai NHỎ hơn luôn là bên khởi tạo ưu tiên, nên hai
/// phía hội tụ về một phiên (có xoay khóa DH sau mỗi lượt đối thoại) dù ai gửi trước.
/// Giới hạn đã biết: khóa danh tính tĩnh bị lộ thì tin ĐẦU TIÊN của mỗi phiên có thể bị giải mã (không có prekey).

const int maxSkip = 1000;
final _x = X25519();
final _aes = AesGcm.with256bits();
final _zeros32 = Uint8List(32);
List<int> _t(String s) => utf8.encode(s);

Uint8List Function() secureRandom32 = () {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256)));
};

Future<Uint8List> _hkdf(List<int> ikm, List<int> salt, List<int> info, int len) async {
  final k = await Hkdf(hmac: Hmac.sha256(), outputLength: len).deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);
  return Uint8List.fromList(await k.extractBytes());
}

Future<Uint8List> _hmac(List<int> key, List<int> data) async =>
    Uint8List.fromList((await Hmac.sha256().calculateMac(data, secretKey: SecretKey(key))).bytes);

class RatchetKey {
  RatchetKey(this.seed, this.pair, this.pub);
  final Uint8List seed;
  final SimpleKeyPair pair;
  final Uint8List pub;

  static Future<RatchetKey> fromSeed(List<int> seed) async {
    final p = await _x.newKeyPairFromSeed(seed);
    return RatchetKey(Uint8List.fromList(seed), p, Uint8List.fromList((await p.extractPublicKey()).bytes));
  }
}

Future<Uint8List> _dh(RatchetKey mine, List<int> peerPub) async {
  final s = await _x.sharedSecretKey(keyPair: mine.pair, remotePublicKey: SimplePublicKey(peerPub, type: KeyPairType.x25519));
  return Uint8List.fromList(await s.extractBytes());
}

Future<(Uint8List, Uint8List)> _kdfRk(Uint8List rk, Uint8List dhOut) async {
  final o = await _hkdf(dhOut, rk, _t('cham-dr-rk'), 64);
  return (Uint8List.sublistView(o, 0, 32), Uint8List.sublistView(o, 32));
}

Future<(Uint8List, Uint8List)> _kdfCk(Uint8List ck) async => (await _hmac(ck, [2]), await _hmac(ck, [1])); // (ck', mk)

String _hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
bool _eq(List<int>? a, List<int>? b) {
  if (a == null || b == null || a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

class RatchetException implements Exception {
  RatchetException(this.code);
  final String code;
  @override
  String toString() => 'RatchetException($code)';
}

enum RatchetRole { init, resp }

class Ratchet {
  Ratchet._({
    required this.role,
    required this.ident,
    required this.rk,
    required this.dhs,
    this.dhr,
    this.cks,
    this.ckr,
    this.ns = 0,
    this.nr = 0,
    this.pn = 0,
    Map<String, Uint8List>? skipped,
  }) : skipped = skipped ?? <String, Uint8List>{};

  RatchetRole role;
  Uint8List ident;
  Uint8List rk;
  RatchetKey dhs;
  Uint8List? dhr;
  Uint8List? cks;
  Uint8List? ckr;
  int ns, nr, pn;
  Map<String, Uint8List> skipped;

  bool get canSend => cks != null;
  int get flag => role == RatchetRole.init ? 1 : 0;

  static Future<Ratchet> create({
    required RatchetRole role,
    required RatchetKey myIdentity,
    required Uint8List peerPub,
    required Uint8List Function() rand,
  }) async {
    final initPub = role == RatchetRole.init ? myIdentity.pub : peerPub;
    final respPub = role == RatchetRole.init ? peerPub : myIdentity.pub;
    final rk0 = await _hkdf(await _dh(myIdentity, peerPub), _zeros32, [..._t('cham-dr-v1'), ...initPub, ...respPub], 32);
    final ident = Uint8List.fromList([...initPub, ...respPub]);
    if (role == RatchetRole.init) {
      final dhs = await RatchetKey.fromSeed(rand());
      final (rk, cks) = await _kdfRk(rk0, await _dh(dhs, peerPub));
      return Ratchet._(role: role, ident: ident, rk: rk, dhs: dhs, dhr: Uint8List.fromList(peerPub), cks: cks);
    }
    return Ratchet._(role: role, ident: ident, rk: rk0, dhs: myIdentity);
  }

  Ratchet clone() => Ratchet._(
        role: role, ident: ident, rk: rk, dhs: dhs, dhr: dhr, cks: cks, ckr: ckr, ns: ns, nr: nr, pn: pn,
        skipped: Map<String, Uint8List>.of(skipped),
      );

  void _become(Ratchet o) {
    rk = o.rk; dhs = o.dhs; dhr = o.dhr; cks = o.cks; ckr = o.ckr; ns = o.ns; nr = o.nr; pn = o.pn; skipped = o.skipped;
  }

  static Uint8List _header(List<int> dhPub, int pn, int n) {
    final h = Uint8List(40)..setRange(0, 32, dhPub);
    final bd = ByteData.sublistView(h);
    bd.setUint32(32, pn);
    bd.setUint32(36, n);
    return h;
  }

  List<int> _aad(int flag, List<int> header) => [..._t('cham-dr2'), flag, ...header, ...ident];

  static Future<(Uint8List, Uint8List)> _aeadKey(Uint8List mk) async {
    final o = await _hkdf(mk, _zeros32, _t('cham-dr-msg'), 44);
    return (Uint8List.sublistView(o, 0, 32), Uint8List.sublistView(o, 32));
  }

  Future<String> encrypt(String plain) async {
    final c = cks;
    if (c == null) throw RatchetException('NO_SEND_CHAIN');
    final (ck, mk) = await _kdfCk(c);
    final header = _header(dhs.pub, pn, ns);
    final (key, iv) = await _aeadKey(mk);
    final box = await _aes.encrypt(utf8.encode(plain), secretKey: SecretKey(key), nonce: iv, aad: _aad(flag, header));
    cks = ck;
    ns += 1;
    return 'dr2:${base64.encode([2, flag, ...header, ...box.cipherText, ...box.mac.bytes])}';
  }

  /// Nguyên tử: lỗi thì trạng thái không đổi.
  Future<String> decrypt(String wire, Uint8List Function() rand) async {
    final work = clone();
    final out = await work._decrypt(wire, rand);
    _become(work);
    return out;
  }

  Future<String> _decrypt(String wire, Uint8List Function() rand) async {
    if (!wire.startsWith('dr2:')) throw RatchetException('BAD_FORMAT');
    final raw = base64.decode(wire.substring(4));
    if (raw.length < 2 + 40 + 16 || raw[0] != 2) throw RatchetException('BAD_FORMAT');
    final fl = raw[1];
    if (fl != (role == RatchetRole.init ? 0 : 1)) throw RatchetException('WRONG_SESSION');
    final header = Uint8List.sublistView(raw, 2, 42);
    final ct = Uint8List.sublistView(raw, 42);
    final dhPub = Uint8List.sublistView(header, 0, 32);
    final bd = ByteData.sublistView(header);
    final pnH = bd.getUint32(32);
    final n = bd.getUint32(36);
    final sk = skipped['${_hex(dhPub)}:$n'];
    if (sk != null) {
      final plain = await _open(sk, fl, header, ct);
      skipped.remove('${_hex(dhPub)}:$n');
      return plain;
    }
    if (dhr == null || !_eq(dhPub, dhr)) {
      await _skip(pnH);
      pn = ns;
      ns = 0;
      nr = 0;
      dhr = Uint8List.fromList(dhPub);
      final (rk1, ckr1) = await _kdfRk(rk, await _dh(dhs, dhr!));
      rk = rk1;
      ckr = ckr1;
      dhs = await RatchetKey.fromSeed(rand());
      final (rk2, cks2) = await _kdfRk(rk, await _dh(dhs, dhr!));
      rk = rk2;
      cks = cks2;
    }
    await _skip(n);
    final (ck, mk) = await _kdfCk(ckr!);
    final plain = await _open(mk, fl, header, ct);
    ckr = ck;
    nr += 1;
    return plain;
  }

  Future<void> _skip(int until) async {
    if (ckr == null) return;
    if (until - nr > maxSkip) throw RatchetException('TOO_MANY_SKIPPED');
    while (nr < until) {
      final (ck, mk) = await _kdfCk(ckr!);
      skipped['${_hex(dhr!)}:$nr'] = mk;
      ckr = ck;
      nr += 1;
    }
    while (skipped.length > maxSkip) {
      skipped.remove(skipped.keys.first);
    }
  }

  Future<String> _open(Uint8List mk, int fl, Uint8List header, Uint8List ct) async {
    final (key, iv) = await _aeadKey(mk);
    final body = Uint8List.sublistView(ct, 0, ct.length - 16);
    final tag = Uint8List.sublistView(ct, ct.length - 16);
    final clear = await _aes.decrypt(SecretBox(body, nonce: iv, mac: Mac(tag)), secretKey: SecretKey(key), aad: _aad(fl, header));
    return utf8.decode(clear);
  }

  Map<String, Object?> toJson() => {
        'v': 1,
        'role': role == RatchetRole.init ? 'init' : 'resp',
        'ident': base64.encode(ident),
        'rk': base64.encode(rk),
        'dhsSeed': base64.encode(dhs.seed),
        'dhr': dhr == null ? null : base64.encode(dhr!),
        'cks': cks == null ? null : base64.encode(cks!),
        'ckr': ckr == null ? null : base64.encode(ckr!),
        'ns': ns,
        'nr': nr,
        'pn': pn,
        'skipped': [for (final e in skipped.entries) [e.key, base64.encode(e.value)]],
      };

  static Future<Ratchet> fromJson(Map<String, dynamic> j) async {
    Uint8List? b(Object? v) => v == null ? null : Uint8List.fromList(base64.decode(v as String));
    return Ratchet._(
      role: j['role'] == 'init' ? RatchetRole.init : RatchetRole.resp,
      ident: b(j['ident'])!,
      rk: b(j['rk'])!,
      dhs: await RatchetKey.fromSeed(b(j['dhsSeed'])!),
      dhr: b(j['dhr']),
      cks: b(j['cks']),
      ckr: b(j['ckr']),
      ns: j['ns'] as int,
      nr: j['nr'] as int,
      pn: j['pn'] as int,
      skipped: {for (final e in (j['skipped'] as List)) (e as List)[0] as String: b(e[1])!},
    );
  }
}

/// Hai phiên của một cặp người dùng. Gọi [snapshot] sau mỗi encrypt/decrypt thành công để lưu xuống ổ đĩa
/// (lưu TRƯỚC khi gửi tin đi, để mất điện không làm lặp khóa).
class RatchetConversation {
  RatchetConversation({required this.me, required this.peerPub, Uint8List Function()? rand, this.mine, this.theirs})
      : rand = rand ?? secureRandom32;

  final RatchetKey me;
  final Uint8List peerPub;
  final Uint8List Function() rand;
  Ratchet? mine;
  Ratchet? theirs;

  bool get iAmSmaller {
    for (var i = 0; i < 32; i++) {
      if (me.pub[i] != peerPub[i]) return me.pub[i] < peerPub[i];
    }
    return false;
  }

  Future<String> encrypt(String plain) async {
    final t = theirs;
    if (!iAmSmaller && t != null && t.canSend) return t.encrypt(plain);
    mine ??= await Ratchet.create(role: RatchetRole.init, myIdentity: me, peerPub: peerPub, rand: rand);
    return mine!.encrypt(plain);
  }

  Future<String> decrypt(String wire) async {
    if (!wire.startsWith('dr2:')) throw RatchetException('BAD_FORMAT');
    final raw = base64.decode(wire.substring(4));
    if (raw.length < 2) throw RatchetException('BAD_FORMAT');
    if (raw[1] == 1) {
      theirs ??= await Ratchet.create(role: RatchetRole.resp, myIdentity: me, peerPub: peerPub, rand: rand);
      return theirs!.decrypt(wire, rand);
    }
    final m = mine;
    if (m == null) throw RatchetException('NO_SESSION');
    return m.decrypt(wire, rand);
  }

  Map<String, Object?> snapshot() => {'mine': mine?.toJson(), 'theirs': theirs?.toJson()};

  static Future<RatchetConversation> restore({
    required RatchetKey me,
    required Uint8List peerPub,
    Uint8List Function()? rand,
    Map<String, dynamic>? state,
  }) async =>
      RatchetConversation(
        me: me,
        peerPub: peerPub,
        rand: rand,
        mine: state?['mine'] == null ? null : await Ratchet.fromJson(Map<String, dynamic>.from(state!['mine'] as Map)),
        theirs: state?['theirs'] == null ? null : await Ratchet.fromJson(Map<String, dynamic>.from(state!['theirs'] as Map)),
      );
}
