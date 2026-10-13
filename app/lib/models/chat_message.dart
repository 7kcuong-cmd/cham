enum ChatStatus { sending, sent, read, received, failed }

/// Một tin nhắn lưu trên máy (không lưu nội dung gốc trên server).
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.mine,
    required this.text,
    required this.at,
    required this.status,
  });

  final String id;
  final String peerId;
  final bool mine;
  final String text;
  final DateTime at;
  final ChatStatus status;

  ChatMessage withStatus(ChatStatus s) =>
      ChatMessage(id: id, peerId: peerId, mine: mine, text: text, at: at, status: s);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'peerId': peerId,
        'mine': mine,
        'text': text,
        'at': at.toUtc().toIso8601String(),
        'status': status.name,
      };

  static ChatMessage? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final peer = j['peerId'];
    final mine = j['mine'];
    final text = j['text'];
    final at = j['at'] is String ? DateTime.tryParse(j['at'] as String) : null;
    final st = ChatStatus.values.where((s) => s.name == j['status']);
    if (id is! String || peer is! String || mine is! bool || text is! String || at == null || st.isEmpty) {
      return null;
    }
    return ChatMessage(id: id, peerId: peer, mine: mine, text: text, at: at, status: st.first);
  }
}
