import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/contact.dart';
import '../models/invite.dart';
import '../models/ws_messages.dart';
import '../services/permission_gateway.dart';
import '../services/ws_client.dart';
import '../utils/countdown.dart';
import 'call_context.dart';
import 'swipe_controller.dart' show TimerFactory;

enum InviteStatus { none, outgoing, incoming }

/// Điều `InviteController` muốn báo cho người dùng (UI đổi thành SnackBar có dịch).
sealed class InviteNotice {
  const InviteNotice();
}

/// Lời mời kết thúc không thành cuộc gọi. [outgoing] = lời mời do mình gọi đi.
final class InviteEndedNotice extends InviteNotice {
  const InviteEndedNotice(this.reason, {required this.outgoing});

  /// `declined` | `cancelled` | `timeout` | `busy` | `failed`
  final String reason;
  final bool outgoing;
}

/// Lỗi cần báo: mã trong API-GD2-4 §4, hoặc mã cục bộ `NETWORK` / `PERMISSION_DENIED`.
final class InviteErrorNotice extends InviteNotice {
  const InviteErrorNotice(this.code);
  final String code;
}

/// Gọi lại bạn bè – gọi đi và gọi đến (API-GD2-4 §3.2, T-108).
///
/// Nhận `call.inviting` / `call.invite` / `call.invite.ended`; gửi `call.invite`, `call.accept`,
/// `call.decline`, `call.invite.cancel`. Cuộc gọi thật bắt đầu bằng `match.found` y hệt cuộc gọi
/// ngẫu nhiên, do `SwipeController` xử lý (ở đây chỉ báo trước qua [InvitedCallHost]).
class InviteController extends ChangeNotifier {
  InviteController({
    required WsClient ws,
    required PermissionGateway permissions,
    required InvitedCallHost swipe,
    Stream<String>? openedInviteIds,
    TimerFactory? timerFactory,
    DateTime Function()? now,
  })  : _ws = ws,
        _permissions = permissions,
        _swipe = swipe,
        _timerFactory = timerFactory ?? Timer.new,
        _now = now ?? DateTime.now {
    _msgSub = _ws.messages.listen(_onMessage);
    _stateSub = _ws.state.listen(_onWsState);
    _pushSub = openedInviteIds?.listen(_onPushOpened);
  }

  /// Chờ `call.inviting` sau khi gửi `call.invite`; quá hạn coi như mất kết nối.
  static const confirmTimeout = Duration(seconds: 8);

  /// Chờ server phát lại lời mời sau khi mở app từ thông báo đẩy (T-108).
  static const pushWait = Duration(seconds: 10);

  /// Chờ `match.found` sau `call.accept`.
  static const acceptTimeout = Duration(seconds: 10);

  /// Dọn giao diện chậm hơn `expiresAt` một chút nếu server không báo hết hạn (chỉ khi đồng hồ
  /// máy hợp lý, xem [countdownRemaining]).
  static const expiryGrace = Duration(seconds: 5);

  final WsClient _ws;
  final PermissionGateway _permissions;
  final InvitedCallHost _swipe;
  final TimerFactory _timerFactory;
  final DateTime Function() _now;

  late final StreamSubscription<ServerMessage> _msgSub;
  late final StreamSubscription<WsConnState> _stateSub;
  StreamSubscription<String>? _pushSub;
  final StreamController<InviteNotice> _notices = StreamController<InviteNotice>.broadcast();

  // gọi đi
  Contact? _outContact;
  OutgoingInvite? _outInvite;
  Timer? _confirmTimer;
  Timer? _outExpiryTimer;
  bool _cancelOnInviting = false;

  // gọi đến
  final List<IncomingInvite> _incoming = <IncomingInvite>[];
  final Map<String, Timer> _inExpiry = <String, Timer>{};
  final Set<String> _fromPush = <String>{};
  bool _accepting = false;
  Timer? _acceptTimer;

  // thông báo đẩy
  String? _awaitedPushId;
  Timer? _pushTimer;

  bool _disposed = false;

  /// Lời mời đến được ưu tiên hơn lời mời đi khi cả hai cùng tồn tại.
  InviteStatus get status {
    if (_incoming.isNotEmpty) return InviteStatus.incoming;
    if (_outContact != null) return InviteStatus.outgoing;
    return InviteStatus.none;
  }

  /// Người đang gọi đi (có ngay khi bấm Gọi, trước khi server xác nhận).
  Contact? get outgoingContact => _outContact;

  /// `null` cho tới khi nhận `call.inviting`.
  OutgoingInvite? get outgoingInvite => _outInvite;

  /// Lời mời đến đang hiện (mới nhất).
  IncomingInvite? get incoming => _incoming.isEmpty ? null : _incoming.last;

  /// Đã bấm Nghe, đang chờ `match.found`.
  bool get accepting => _accepting;

  /// Lời mời đang hiện là lời mời mà người dùng vừa bấm thông báo đẩy để mở.
  bool get incomingFromPush => incoming != null && _fromPush.contains(incoming!.inviteId);

  /// `inviteId` từ thông báo đẩy đang chờ server phát lại.
  String? get awaitedPushInviteId => _awaitedPushId;

  Stream<InviteNotice> get notices => _notices.stream;

  // --- hành động người dùng ---------------------------------------------------------

  /// Gọi lại [contact]. Trả `false` nếu không bắt đầu được (đang có lời mời khác, đang trong cuộc
  /// gọi, chưa kết nối, hoặc bị từ chối quyền camera/micro – các trường hợp sau có [InviteNotice]).
  Future<bool> invite(Contact contact) async {
    if (status != InviteStatus.none || _swipe.inCallOrConnecting) return false;
    if (!_ws.isConnected) {
      _notice(const InviteErrorNotice('NETWORK'));
      return false;
    }
    if (!await _ensurePermissions()) {
      _notice(const InviteErrorNotice('PERMISSION_DENIED'));
      return false;
    }
    // Trong lúc chờ hộp thoại quyền, trạng thái có thể đã đổi.
    if (status != InviteStatus.none || _swipe.inCallOrConnecting || !_ws.isConnected) {
      return false;
    }
    _cancelOnInviting = false;
    _outContact = contact;
    _outInvite = null;
    _confirmTimer?.cancel();
    _confirmTimer = _timerFactory(confirmTimeout, _onConfirmTimeout);
    _ws.send('call.invite', <String, dynamic>{'contactId': contact.id});
    _notify();
    return true;
  }

  /// Hủy lời mời đi. Nếu server chưa xác nhận (chưa có `inviteId`) thì hủy ngay khi xác nhận tới.
  void cancel() {
    final contact = _outContact;
    if (contact == null) return;
    final inv = _outInvite;
    if (inv == null) {
      _cancelOnInviting = true;
    } else {
      _ws.send('call.invite.cancel', <String, dynamic>{'inviteId': inv.inviteId});
    }
    _clearOutgoing();
    _swipe.clearInvitedCall();
    _notify();
  }

  /// Nghe máy. Cần quyền camera + micro; bị từ chối → từ chối cuộc gọi (T-109).
  Future<void> accept() async {
    final inv = incoming;
    if (inv == null || _accepting) return;
    _accepting = true;
    _notify();
    final granted = await _ensurePermissions();
    if (_disposed) return;
    if (incoming?.inviteId != inv.inviteId) {
      // Lời mời đã kết thúc trong lúc chờ hộp thoại quyền.
      _accepting = false;
      _notify();
      return;
    }
    if (!granted) {
      _accepting = false;
      decline();
      _notice(const InviteErrorNotice('PERMISSION_DENIED'));
      return;
    }
    _clearOutgoing(); // server tự hủy lời mời đi của mình khi nhận accept
    _swipe.expectInvitedCall();
    _ws.send('call.accept', <String, dynamic>{'inviteId': inv.inviteId});
    _acceptTimer?.cancel();
    _acceptTimer = _timerFactory(acceptTimeout, _onAcceptTimeout);
    _notify();
  }

  /// Từ chối lời mời đang hiện.
  void decline() {
    final inv = incoming;
    if (inv == null) return;
    _removeIncoming(inv.inviteId);
    if (_incoming.isEmpty) _stopAccepting();
    _ws.send('call.decline', <String, dynamic>{'inviteId': inv.inviteId});
    _notify();
  }

  // --- WebSocket --------------------------------------------------------------------

  void _onMessage(ServerMessage m) {
    switch (m) {
      case final CallInviting e:
        _onInviting(e.invite);
      case final CallInviteIncoming e:
        _onIncoming(e.invite);
      case final CallInviteEnded e:
        _onEnded(e);
      case MatchFoundEvent():
        _onMatchFound();
      case final ServerError e:
        _onError(e);
      default:
        break;
    }
  }

  void _onWsState(WsConnState s) {
    if (s == WsConnState.connected) return;
    // Server hủy lời mời đi khi người gọi đóng kết nối; lời mời đến được phát lại sau kết nối lại.
    if (_outContact != null || _accepting) {
      _clearOutgoing();
      _stopAccepting();
      _swipe.clearInvitedCall();
      _notify();
    }
  }

  void _onInviting(OutgoingInvite inv) {
    final contact = _outContact;
    if (contact == null) {
      if (_cancelOnInviting) {
        _cancelOnInviting = false;
        _ws.send('call.invite.cancel', <String, dynamic>{'inviteId': inv.inviteId});
      }
      return;
    }
    if (contact.id != inv.contactId) return;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _outInvite = inv;
    _swipe.expectInvitedCall();
    _outExpiryTimer?.cancel();
    _outExpiryTimer = _expiryTimer(inv.expiresAt, _onOutgoingExpired);
    _notify();
  }

  void _onIncoming(IncomingInvite inv) {
    // Server coi mình là `busy` khi đang gọi nên thường không tới; nếu tới thì bỏ qua (T-108).
    if (_swipe.inCallOrConnecting) return;
    _incoming.removeWhere((i) => i.inviteId == inv.inviteId);
    _incoming.add(inv);
    _inExpiry[inv.inviteId]?.cancel();
    final timer = _expiryTimer(inv.expiresAt, () => _onIncomingExpired(inv.inviteId));
    if (timer != null) _inExpiry[inv.inviteId] = timer;
    if (_awaitedPushId == inv.inviteId) {
      _fromPush.add(inv.inviteId);
      _awaitedPushId = null;
      _pushTimer?.cancel();
      _pushTimer = null;
    }
    _notify();
  }

  void _onEnded(CallInviteEnded e) {
    final out = _outInvite;
    final awaitingOutgoing = _outContact != null && out == null;
    if ((out != null && out.inviteId == e.inviteId) ||
        (awaitingOutgoing && e.reason == CallInviteEnded.busy)) {
      _clearOutgoing();
      _swipe.clearInvitedCall();
      _notice(InviteEndedNotice(e.reason, outgoing: true));
      _notify();
      return;
    }
    if (_incoming.any((i) => i.inviteId == e.inviteId)) {
      final wasAccepting = _accepting && incoming?.inviteId == e.inviteId;
      _removeIncoming(e.inviteId);
      if (wasAccepting || _incoming.isEmpty) _stopAccepting();
      if (wasAccepting) _swipe.clearInvitedCall();
      _notice(InviteEndedNotice(e.reason, outgoing: false));
      _notify();
    }
  }

  void _onMatchFound() {
    // Đã vào cuộc gọi (gọi lại bạn hoặc ghép ngẫu nhiên): mọi lời mời còn lại vô nghĩa.
    if (_outContact == null && _incoming.isEmpty && !_accepting) return;
    _clearOutgoing();
    for (final id in _incoming.map((i) => i.inviteId).toList()) {
      _removeIncoming(id);
    }
    _stopAccepting();
    _notify();
  }

  void _onError(ServerError e) {
    final awaitingOutgoing = _outContact != null && _outInvite == null;
    switch (e.code) {
      case 'CONTACT_NOT_FOUND':
      case 'INVITE_PENDING':
      case 'PROFILE_INCOMPLETE':
      case 'FEATURE_DISABLED':
        if (!awaitingOutgoing) return;
        _failOutgoing(e.code);
      case 'RATE_LIMITED':
        // SwipeController đã hiện thông báo giới hạn tốc độ; ở đây chỉ rút lui.
        if (!awaitingOutgoing) return;
        _failOutgoing(null);
      case 'INVALID_STATE':
        if (awaitingOutgoing) {
          _failOutgoing(e.code);
        } else if (_accepting) {
          _failAccepting();
        }
      case 'INVITE_NOT_FOUND':
        // Chỉ có ý nghĩa khi đang nghe máy: lời mời đã hết hạn/bị hủy. Hủy/từ chối muộn thì bỏ qua.
        if (_accepting) _failAccepting();
      default:
        break;
    }
  }

  // --- hết giờ / dọn dẹp -------------------------------------------------------------

  void _onConfirmTimeout() {
    _confirmTimer = null;
    if (_outContact != null && _outInvite == null) _failOutgoing('NETWORK');
  }

  void _onOutgoingExpired() {
    _outExpiryTimer = null;
    if (_outInvite == null) return;
    _clearOutgoing();
    _swipe.clearInvitedCall();
    _notice(const InviteEndedNotice(CallInviteEnded.timeout, outgoing: true));
    _notify();
  }

  void _onIncomingExpired(String inviteId) {
    _inExpiry.remove(inviteId);
    if (!_incoming.any((i) => i.inviteId == inviteId)) return;
    final wasAccepting = _accepting && incoming?.inviteId == inviteId;
    _removeIncoming(inviteId);
    if (wasAccepting || _incoming.isEmpty) _stopAccepting();
    if (wasAccepting) _swipe.clearInvitedCall();
    _notify();
  }

  void _onAcceptTimeout() {
    _acceptTimer = null;
    if (_accepting) _failAccepting();
  }

  /// Hẹn dọn lời mời [grace] sau `expiresAt` nếu đồng hồ máy hợp lý; ngược lại không hẹn.
  Timer? _expiryTimer(DateTime expiresAt, void Function() callback) {
    final remaining = countdownRemaining(expiresAt, _now());
    if (remaining == null) return null;
    return _timerFactory(remaining + expiryGrace, callback);
  }

  void _failOutgoing(String? code) {
    _clearOutgoing();
    _swipe.clearInvitedCall();
    if (code != null) _notice(InviteErrorNotice(code));
    _notify();
  }

  void _failAccepting() {
    final inv = incoming;
    if (inv != null) _removeIncoming(inv.inviteId);
    _stopAccepting();
    _swipe.clearInvitedCall();
    _notice(const InviteEndedNotice(CallInviteEnded.cancelled, outgoing: false));
    _notify();
  }

  void _clearOutgoing() {
    _outContact = null;
    _outInvite = null;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _outExpiryTimer?.cancel();
    _outExpiryTimer = null;
  }

  void _removeIncoming(String inviteId) {
    _incoming.removeWhere((i) => i.inviteId == inviteId);
    _inExpiry.remove(inviteId)?.cancel();
    _fromPush.remove(inviteId);
  }

  void _stopAccepting() {
    _accepting = false;
    _acceptTimer?.cancel();
    _acceptTimer = null;
  }

  // --- thông báo đẩy -----------------------------------------------------------------

  void _onPushOpened(String inviteId) {
    if (_incoming.any((i) => i.inviteId == inviteId)) {
      _fromPush.add(inviteId);
      _notify();
      return;
    }
    _awaitedPushId = inviteId;
    _pushTimer?.cancel();
    _pushTimer = _timerFactory(pushWait, () {
      _pushTimer = null;
      _awaitedPushId = null;
      _notify();
    });
    _notify();
  }

  // --- tiện ích ----------------------------------------------------------------------

  Future<bool> _ensurePermissions() async {
    if (await _permissions.hasCameraAndMic()) return true;
    return await _permissions.request() == PermissionOutcome.granted;
  }

  void _notice(InviteNotice n) {
    if (!_notices.isClosed) _notices.add(n);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearOutgoing();
    _stopAccepting();
    for (final t in _inExpiry.values) {
      t.cancel();
    }
    _inExpiry.clear();
    _pushTimer?.cancel();
    _msgSub.cancel();
    _stateSub.cancel();
    _pushSub?.cancel();
    _notices.close();
    super.dispose();
  }
}
