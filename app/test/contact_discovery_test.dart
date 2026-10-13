import 'package:cham/models/discovery.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/state/contacts_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('parseContactCodeFromScan nhận mã trần và liên kết cham://add/', () {
    const code = 'c1.abcDEF123_-xyzabcdefghi.S6MN9-GLq0vj';
    expect(parseContactCodeFromScan(code), code);
    expect(parseContactCodeFromScan('cham://add/$code'), code);
    expect(parseContactCodeFromScan(' $code '), code);
    expect(parseContactCodeFromScan('https://evil.example/x'), isNull);
    expect(parseContactCodeFromScan('c1.abc.short'), isNull);
  });

  test('UserHit / ContactRequest bỏ qua phần tử sai dạng', () {
    expect(UserHit.tryParse({'id': 'u', 'displayName': 'An', 'relation': 'contact'})?.relation, 'contact');
    expect(UserHit.tryParse({'id': 'u'}), isNull);
    expect(ContactRequest.tryParse({'userId': 'u', 'displayName': 'An'})?.displayName, 'An');
    expect(ContactRequest.tryParse('x'), isNull);
  });

  test('ws contact.request / contact.new được phân tích', () {
    final r = ServerMessage.parse('{"type":"contact.request","data":{"userId":"u1","displayName":"An"}}');
    expect(r, isA<ContactRequestIncoming>());
    final n = ServerMessage.parse('{"type":"contact.new","data":{"userId":"u1","displayName":"An"}}');
    expect(n, isA<ContactNew>());
    expect(ServerMessage.parse('{"type":"contact.new","data":{}}'), isA<UnknownMessage>());
  });

  test('ContactsController: contact.request thêm vào requests, contact.new tải lại danh bạ', () async {
    final api = FakeApiClient();
    final ws = FakeWsClient();
    final c = ContactsController(api: api, ws: ws, room: FakeRoom());
    addTearDown(c.dispose);
    final events = <FriendEvent>[];
    c.events.listen(events.add);

    ws.emit(const ContactRequestIncoming('u1', 'An'));
    await _settle();
    expect(c.requests.single.userId, 'u1');
    expect(events.single.kind, FriendEventKind.requestReceived);

    api.onGetContacts = () async => [makeContact(id: 'u1', name: 'An')];
    ws.emit(const ContactNew('u1', 'An'));
    await _settle();
    await _settle();
    expect(c.requests, isEmpty);
    expect(c.isContact('u1'), isTrue);
  });
}
