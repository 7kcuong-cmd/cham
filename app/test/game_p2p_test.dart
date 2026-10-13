import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cham/games/game_models.dart';
import 'package:cham/games/game_session.dart';
import 'package:cham/games/game_store.dart';
import 'package:cham/services/call_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Call implements CallService {
  final StreamController<Map<String, dynamic>> inbox = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  _Call? peer;
  bool open = true;
  final List<Map<String, dynamic>> sent = [];
  @override
  Stream<Map<String, dynamic>> get dataMessages => inbox.stream;
  @override
  bool sendData(Map<String, dynamic> message) {
    if (!open) return false;
    sent.add(message);
    peer?.inbox.add(jsonDecode(jsonEncode(message)) as Map<String, dynamic>);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<(List<int>, GameCatalogEntry, Uint8List)> _bundle({String version = '1.0.0'}) async {
  final a = Archive()
    ..addFile(ArchiveFile.string('manifest.json', jsonEncode({'id': 'caro', 'version': version})))
    ..addFile(ArchiveFile.string('index.html', '<html></html>'));
  final data = Uint8List.fromList(ZipEncoder().encode(a));
  final sha = GameStore.hex((await Sha256().hash(data)).bytes);
  final alg = Ed25519();
  final kp = await alg.newKeyPair();
  final pub = (await kp.extractPublicKey()).bytes;
  final sig = await alg.sign(GameStore.sigMessage('caro', version, sha), keyPair: kp);
  final e = GameCatalogEntry(
      id: 'caro', version: version, url: 'https://x/caro.cgp', sha256: sha, sig: base64.encode(sig.bytes), nameVi: 'Cờ caro', nameEn: 'Gomoku');
  return (pub, e, data);
}

GameStore _store(Directory d, List<int> pub, http.Client c) => GameStore(rootDir: () async => d, publicKey: pub, client: c);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cgp'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('tải, kiểm chữ ký, cài và dùng lại bản đã có', () async {
    final (pub, e, data) = await _bundle();
    var hits = 0;
    final s = _store(tmp, pub, MockClient((_) async {
      hits++;
      return http.Response.bytes(data, 200);
    }));
    final g = await s.ensure(e);
    expect(File('${g.dir}/index.html').existsSync(), isTrue);
    await s.ensure(e);
    expect(hits, 1);
  });

  test('từ chối chữ ký sai, hash sai, khoá rỗng', () async {
    final (pub, e, data) = await _bundle();
    final bad = GameCatalogEntry(
        id: e.id, version: e.version, url: e.url, sha256: e.sha256, sig: base64.encode(List.filled(64, 1)), nameVi: 'x', nameEn: 'x');
    expect(() => _store(tmp, pub, MockClient((_) async => http.Response.bytes(data, 200))).ensure(bad), throwsA(isA<GameStoreException>()));
    final tampered = Uint8List.fromList(data)..[10] ^= 1;
    expect(() => _store(tmp, pub, MockClient((_) async => http.Response.bytes(tampered, 200))).ensure(e), throwsA(isA<GameStoreException>()));
    expect(() => _store(tmp, const [], MockClient((_) async => http.Response.bytes(data, 200))).ensure(e), throwsA(isA<GameStoreException>()));
  });

  test('từ chối zip có đường dẫn thoát thư mục', () async {
    final a = Archive()
      ..addFile(ArchiveFile.string('manifest.json', jsonEncode({'id': 'caro', 'version': '1.0.0'})))
      ..addFile(ArchiveFile.string('../evil.txt', 'x'));
    final data = Uint8List.fromList(ZipEncoder().encode(a));
    final alg = Ed25519();
    final kp = await alg.newKeyPair();
    final sha = GameStore.hex((await Sha256().hash(data)).bytes);
    final sig = await alg.sign(GameStore.sigMessage('caro', '1.0.0', sha), keyPair: kp);
    final e = GameCatalogEntry(
        id: 'caro', version: '1.0.0', url: 'https://x', sha256: sha, sig: base64.encode(sig.bytes), nameVi: 'x', nameEn: 'x');
    final pub = (await kp.extractPublicKey()).bytes;
    expect(() => _store(tmp, pub, MockClient((_) async => http.Response.bytes(data, 200))).ensure(e), throwsA(isA<GameStoreException>()));
    expect(File('${tmp.path}/evil.txt').existsSync(), isFalse);
  });

  test('mời → chấp nhận → hai bên vào ván, chuyển tin hai chiều', () async {
    final (pub, e, data) = await _bundle();
    final ca = _Call(), cb = _Call();
    ca.peer = cb;
    cb.peer = ca;
    final dirB = Directory('${tmp.path}/b')..createSync();
    GameSessionController mk(_Call c, Directory d) => GameSessionController(
        call: c, store: _store(d, pub, MockClient((_) async => http.Response.bytes(data, 200))), catalog: () => [e]);
    final a = mk(ca, Directory('${tmp.path}/a')..createSync()), b = mk(cb, dirB);
    await a.invite(e);
    expect(a.phase, GamePhase.inviting);
    expect(b.phase, GamePhase.incoming);
    await b.accept();
    expect(a.phase, GamePhase.playing);
    expect(b.phase, GamePhase.playing);
    expect(a.me, 0);
    expect(b.me, 1);
    expect(a.seed, b.seed);

    final got = <Map<String, dynamic>>[];
    b.toGame.listen(got.add);
    a.fromGame(jsonEncode({'t': 'send', 'ch': 'reliable', 'data': {'idx': 3}}));
    expect(got, isEmpty, reason: 'chưa ready thì đệm');
    b.fromGame(jsonEncode({'t': 'ready'}));
    await Future<void>.delayed(Duration.zero);
    expect(got.first['t'], 'init');
    expect(got.last['data'], {'idx': 3});

    a.fromGame(jsonEncode({'t': 'end', 'result': {'result': 'win'}}));
    expect(a.phase, GamePhase.ended);
    expect(a.result, 'win');
  });

  test('giới hạn kích thước và tốc độ', () async {
    final (pub, e, data) = await _bundle();
    final ca = _Call(), cb = _Call();
    ca.peer = cb;
    cb.peer = ca;
    final now = DateTime(2026);
    GameSessionController mk(_Call c, String n) => GameSessionController(
        call: c,
        store: _store(Directory('${tmp.path}/$n')..createSync(), pub, MockClient((_) async => http.Response.bytes(data, 200))),
        catalog: () => [e],
        now: () => now);
    final a = mk(ca, 'a'), b = mk(cb, 'b');
    await a.invite(e);
    await b.accept();
    ca.sent.clear();
    a.fromGame(jsonEncode({'t': 'send', 'ch': 'fast', 'data': 'x' * 2000}));
    expect(ca.sent, isEmpty);
    for (var i = 0; i < 100; i++) {
      a.fromGame(jsonEncode({'t': 'send', 'ch': 'reliable', 'data': i}));
    }
    expect(ca.sent.length, GameSessionController.maxPerSecond);
  });

  test('lời mời game không có trong danh mục bị từ chối; không P2P báo lỗi', () async {
    final (pub, e, data) = await _bundle();
    final ca = _Call(), cb = _Call();
    ca.peer = cb;
    cb.peer = ca;
    final mkStore = (String n) => _store(Directory('${tmp.path}/$n')..createSync(), pub, MockClient((_) async => http.Response.bytes(data, 200)));
    final a = GameSessionController(call: ca, store: mkStore('a'), catalog: () => [e]);
    final b = GameSessionController(call: cb, store: mkStore('b'), catalog: () => const []);
    await a.invite(e);
    expect(a.phase, GamePhase.ended);
    expect(a.notice, 'unsupported');
    expect(b.phase, GamePhase.idle);
    ca.open = false;
    a.reset();
    await a.invite(e);
    expect(a.notice, 'no_p2p');
  });
}
