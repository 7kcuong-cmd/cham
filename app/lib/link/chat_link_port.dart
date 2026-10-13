import '../models/chat_message.dart';
import '../services/chat_store.dart';
import '../services/link_sync.dart';
import '../state/chat_controller.dart';
import '../state/contacts_controller.dart';

/// Nối [LinkHost] với kho tin nhắn và bộ điều khiển chat có sẵn trên điện thoại.
class ChatControllerLinkPort implements LinkChatPort {
  ChatControllerLinkPort({required ChatStore store, required ChatController chat, required ContactsController contacts})
      : _store = store,
        _chat = chat,
        _contacts = contacts;

  final ChatStore _store;
  final ChatController _chat;
  final ContactsController _contacts;

  @override
  Future<List<String>> peers() => _store.peers();

  @override
  Future<List<ChatMessage>> load(String peerId) => _store.load(peerId);

  @override
  Stream<ChatMessage> get changes => _chat.changes;

  @override
  Future<bool> send(String peerId, String text) => _chat.send(peerId, text);

  @override
  Future<Map<String, String>> names() async => {for (final c in _contacts.contacts) c.id: c.displayName};
}
