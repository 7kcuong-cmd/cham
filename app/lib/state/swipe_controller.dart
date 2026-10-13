import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/match_found.dart';
import '../models/ws_messages.dart';
import '../security/ice_guard.dart';
import '../security/shield_controller.dart';
import '../services/call_quality.dart';
import '../services/call_service.dart';
import '../services/permission_gateway.dart';
import '../services/ws_client.dart';
import 'call_context.dart';

enum SwipeStatus {
  needsPermission,
  searching,
  connecting,
  inCall,
  offline,
  blockedPermanently,

  /// Không ở tab Lướt hoặc app ở nền.
  inactive,

  /// Liên tiếp [SwipeController.maxWeakMatches] cuộc gọi phải đi đường dự phòng/không nối được: đã dừng tìm người,
  /// chờ người dùng đổi mạng (Wi‑Fi) rồi bấm thử lại.
  weakNetwork,
}

/// Phần của [SwipeController] mà `SafetyController` cần (để test bằng đối tượng giả).
abstract interface class SwipeActions {
  Future<void> next();
}

/// Cuộc gọi danh bạ kết thúc; [byPeer] = đối phương cúp máy.
class ContactCallEnd {
  const ContactCallEnd({required this.peer, required this.byPeer, this.network = false});
  final Peer peer;
  final bool byPeer;

  /// Kết thúc vì mất kết nối / máy chủ dừng (không ai cúp). HomeShell vẫn về Danh bạ, KHÔNG sang Lướt.
  final bool network;
}

typedef TimerFactory = Timer Function(Duration duration, void Function() callback);

/// Máy trạng thái của màn Lướt – T-011, API.md §2.6/§2.7.
class SwipeController extends ChangeNotifier
    implements SwipeActions, RoomSource, InvitedCallHost {
  SwipeController({
    required WsClient ws,
    required CallService call,
    required PermissionGateway permissions,
    required Future<void> Function() refreshSession,
    TimerFactory? timerFactory,
    DateTime Function()? now,
    this.autoBlock,
    ShieldController? shield,
  })  : _shield = shield ?? ShieldController.instance,
        _ws = ws,
        _call = call,
        _permissions = permissions,
        _refreshSession = refreshSession,
        _timerFactory = timerFactory ?? Timer.new,
        _now = now ?? DateTime.now {
    _msgSub = _ws.messages.listen(_onMessage);
    _stateSub = _ws.state.listen(_onWsState);
    _callSub = _call.events.listen(_onCallEvent);
  }

  /// Hết 30 s (P2P ~8 s + dự phòng LiveKit ~12 s) kể từ `match.found` mà chưa thấy video đối phương → `call.next`.
  static const matchTimeout = Duration(seconds: 35); // lưới an toàn: bộ điều phối chất lượng (call_quality.dart) dừng sớm hơn ở 10 s (lướt) / 30 s (gọi bạn)

  /// Bỏ qua vuốt mới trong 800 ms.
  static const swipeDebounce = Duration(milliseconds: 800);

  /// Chờ server báo `call.ended` sau khi LiveKit báo đối phương rời.
  static const remoteLeftGrace = Duration(seconds: 3);

  static const providerRetry = Duration(seconds: 5);
  static const defaultRateLimitRetry = Duration(seconds: 5);

  /// Số cuộc gọi đầu tiên có hiện gợi ý vuốt.
  static const maxSwipeHints = 3;

  /// Chặn tự động đối phương bị phát hiện dò IP (nối vào `POST /v1/blocks` ở app.dart). Lỗi được bỏ qua.
  final Future<void> Function(Peer peer)? autoBlock;
  final ShieldController _shield;

  final WsClient _ws;
  final CallService _call;
  final PermissionGateway _permissions;
  final Future<void> Function() _refreshSession;
  final TimerFactory _timerFactory;
  final DateTime Function() _now;

  late final StreamSubscription<ServerMessage> _msgSub;
  late final StreamSubscription<WsConnState> _stateSub;
  late final StreamSubscription<CallEvent> _callSub;
  final StreamController<String> _notices = StreamController<String>.broadcast();

  Timer? _matchTimer;
  Timer? _remoteLeftTimer;
  Timer? _retryTimer;

  SwipeStatus _status = SwipeStatus.inactive;
  MatchFound? _current;
  bool _micOn = true;
  bool _camOn = true;
  DateTime? _searchStartedAt;
  int _swipeHintsShown = 0;
  bool _hintForCurrent = false;
  bool _permanentlyDenied = false;
  String? _blockedCode;

  bool _active = false;
  bool _wasConnected = false;
  DateTime? _lastNextAt;
  bool _disposed = false;

  /// `match.found` sắp tới là cuộc gọi lại bạn bè (T-108): nhận kể cả khi đang ở tab khác.
  bool _expectInvited = false;

  /// Đã từng vào Lướt trong phiên này (để màn hình phân biệt "chưa bắt đầu" với "đang tạm dừng").
  bool _started = false;
  bool get hasStarted => _started;

  /// Cuộc gọi hiện tại là cuộc gọi từ danh bạ (không phải lướt ngẫu nhiên).
  bool _currentIsContact = false;
  final StreamController<ContactCallEnd> _contactEnds =
      StreamController<ContactCallEnd>.broadcast();

  /// Đang trong cuộc gọi danh bạ: vuốt = cúp máy, không đổi người.
  /// Số cuộc gọi lướt liên tiếp mà P2P không ổn định (phải relay hoặc không nối được). Về 0 khi có P2P ổn định hoặc vào lại tab.
  static const maxWeakMatches = 3;
  int _weakStreak = 0;
  int get weakStreak => _weakStreak;

  CallQualityLevel _callQuality = CallQualityLevel.full;

  /// Mức chất lượng gửi đang áp dụng (chỉ khác `full` khi đi qua relay dự phòng).
  CallQualityLevel get callQuality => _callQuality;

  bool get isContactCall => _currentIsContact && _current != null;

  /// Cuộc gọi danh bạ vừa kết thúc (mình cúp hoặc bạn cúp): HomeShell quay về tab Danh bạ.
  Stream<ContactCallEnd> get contactCallEnds => _contactEnds.stream;

  SwipeStatus get status => _status;
  MatchFound? get current => _current;
  bool get micOn => _micOn;
  bool get camOn => _camOn;
  DateTime? get searchStartedAt => _searchStartedAt;
  int get swipeHintsShown => _swipeHintsShown;
  bool get permanentlyDenied => _permanentlyDenied;

  @override
  String? get roomName => _current?.roomName;

  @override
  Peer? get peer => _current?.peer;

  @override
  bool get inCallOrConnecting =>
      _status == SwipeStatus.connecting || _status == SwipeStatus.inCall;

  @override
  void expectInvitedCall() => _expectInvited = true;

  @override
  void clearInvitedCall() {
    _expectInvited = false;
    // Nghe máy lúc đang ở hàng chờ: server đã rút mình khỏi hàng chờ khi nhận `call.accept`. Nếu cuộc gọi hỏng
    // (hết hạn/hủy/INVALID_STATE) mà không vào lại hàng chờ thì màn hình cứ quay "đang tìm" mà server coi là idle.
    // `queue.join` thừa chỉ nhận lại `queue.joined`.
    if (_active && _status == SwipeStatus.searching && _current == null && _ws.isConnected) _sendJoin();
  }

  /// Mã lỗi khiến [SwipeStatus.blockedPermanently] (ví dụ `SESSION_REPLACED`).
  String? get blockedCode => _blockedCode;

  /// Hiện gợi ý vuốt (chỉ 3 cuộc gọi đầu).
  bool get showSwipeHint =>
      _status == SwipeStatus.inCall && (_hintForCurrent || _currentIsContact);

  /// Có thể bắt đầu vuốt không (UI dùng để quyết định chạy hiệu ứng).
  bool get canSwipe {
    if (_status != SwipeStatus.connecting && _status != SwipeStatus.inCall) return false;
    final last = _lastNextAt;
    return last == null || _now().difference(last) >= swipeDebounce;
  }

  /// Mã lỗi để UI hiện SnackBar (`RATE_LIMITED`, `CALL_PROVIDER_ERROR`, `SESSION_REPLACED`).
  Stream<String> get notices => _notices.stream;

  // --- vòng đời tab -----------------------------------------------------------

  /// Vào tab Lướt (app ở foreground).
  Future<void> activate() async {
    if (_status == SwipeStatus.blockedPermanently) return;
    if (_active && _status != SwipeStatus.inactive && _status != SwipeStatus.needsPermission && _status != SwipeStatus.weakNetwork) {
      return;
    }
    _active = true;
    _started = true;
    _weakStreak = 0;
    final granted = await _permissions.hasCameraAndMic();
    if (!_active) return; // đã rời tab trong lúc chờ
    if (!granted) {
      _setStatus(SwipeStatus.needsPermission);
      return;
    }
    _beginSearching();
  }

  /// Rời tab Lướt hoặc app vào nền.
  Future<void> deactivate() async {
    _active = false;
    _cancelAllTimers();
    if (_status == SwipeStatus.blockedPermanently || _status == SwipeStatus.inactive) return;
    final cur = _current;
    final wasSearching = _status == SwipeStatus.searching;
    _contactAtDeactivate = _currentIsContact;
    _current = null;
    _currentIsContact = false;
    _setStatus(SwipeStatus.inactive);
    final wasContact = _contactAtDeactivate;
    if (cur != null) {
      await _call.leave();
      _ws.send('call.end', <String, dynamic>{'roomName': cur.roomName});
      // Cuộc gọi danh bạ bị ngắt vì rời tab / ra nền: báo để màn hình về Danh bạ, không để rơi vào Lướt.
      if (wasContact) _emitContactEnd(cur.peer, byPeer: false);
    } else if (wasSearching) {
      _ws.send('queue.leave');
    }
  }

  bool _contactAtDeactivate = false;

  /// Đăng xuất: xóa mọi trạng thái (kể cả `blockedPermanently`).
  void reset() {
    _active = false;
    _started = false;
    _cancelAllTimers();
    _current = null;
    _blockedCode = null;
    _expectInvited = false;
    _currentIsContact = false;
    _wasConnected = false;
    _lastNextAt = null;
    _permanentlyDenied = false;
    unawaited(_call.leave());
    _setStatus(SwipeStatus.inactive);
  }

  Future<void> requestPermission() async {
    final outcome = await _permissions.request();
    switch (outcome) {
      case PermissionOutcome.granted:
        _permanentlyDenied = false;
        if (_active) {
          _beginSearching();
        } else {
          notifyListeners();
        }
      case PermissionOutcome.denied:
        notifyListeners();
      case PermissionOutcome.permanentlyDenied:
        _permanentlyDenied = true;
        notifyListeners();
    }
  }

  Future<void> openSystemSettings() => _permissions.openSettings();

  // --- hành động người dùng ------------------------------------------------------

  /// Vuốt: ngắt phòng LiveKit TRƯỚC, rồi gửi `call.next` (API.md §2.7 mục 4).
  @override
  Future<void> next() async {
    final t = _now();
    final last = _lastNextAt;
    if (last != null && t.difference(last) < swipeDebounce) return;
    if (!_active ||
        _status == SwipeStatus.blockedPermanently ||
        _status == SwipeStatus.needsPermission ||
        _status == SwipeStatus.offline ||
        _status == SwipeStatus.inactive) {
      return;
    }
    _lastNextAt = t;
    _cancelCallTimers();
    final cur = _current;
    if (cur != null && _currentIsContact) {
      // Cuộc gọi danh bạ: vuốt lên = cúp máy, bạn nhận `peer_left`.
      _current = null;
      _currentIsContact = false;
      _active = false;
      _setStatus(SwipeStatus.inactive);
      await _call.leave();
      _ws.send('call.end', <String, dynamic>{'roomName': cur.roomName});
      _emitContactEnd(cur.peer, byPeer: false);
      return;
    }
    _current = null;
    _searchStartedAt = t;
    _setStatus(SwipeStatus.searching);
    if (cur != null) {
      await _call.leave();
      _ws.send('call.next', <String, dynamic>{'roomName': cur.roomName});
    } else {
      _ws.send('call.next');
    }
  }

  Future<void> setMic(bool on) async {
    if (_micOn == on) return;
    _micOn = on;
    notifyListeners();
    await _call.setMicEnabled(on);
  }

  Future<void> toggleMic() => setMic(!_micOn);

  Future<void> setCamera(bool on) async {
    if (_camOn == on) return;
    _camOn = on;
    notifyListeners();
    await _call.setCameraEnabled(on);
  }

  Future<void> toggleCamera() => setCamera(!_camOn);

  Future<void> switchCamera() => _call.switchCamera();

  // --- WebSocket ---------------------------------------------------------------

  void _onMessage(ServerMessage m) {
    switch (m) {
      case SessionReady():
        if (_resumeTimer != null && _current != null) {
          // Cuộc gọi danh bạ còn đang giữ: xin server nhận lại phòng thay vì vào hàng chờ.
          _wasConnected = true;
          _ws.send('call.resume', <String, dynamic>{'roomName': _current!.roomName});
        } else {
          _onSessionReady();
        }
      case CallResumed():
        _resumeTimer?.cancel();
        _resumeTimer = null;
      case final MatchFoundEvent event:
        _onMatchFound(event.match);
      case final CallEnded ended:
        unawaited(_onCallEnded(ended));
      case final ServerError error:
        _onServerError(error);
      default:
        // Thông điệp GĐ1 còn lại và mọi thông điệp GĐ2–4 do controller khác xử lý.
        break;
    }
  }

  void _onWsState(WsConnState s) {
    switch (s) {
      case WsConnState.connected:
        _wasConnected = true;
      case WsConnState.disconnected:
      case WsConnState.connecting:
        if (_wasConnected) {
          _wasConnected = false;
          _goOffline();
        }
      case WsConnState.closedPermanently:
        _wasConnected = false;
        _goOffline();
    }
  }

  /// Kết nối (lại) thành công: phía server coi mình là `idle` (API.md §2.7 mục 6).
  void _onSessionReady() {
    _wasConnected = true;
    _expectInvited = false;
    if (!_active ||
        _status == SwipeStatus.blockedPermanently ||
        _status == SwipeStatus.needsPermission ||
        _status == SwipeStatus.inactive) {
      return;
    }
    _cancelAllTimers();
    if (_current != null) {
      _current = null;
      unawaited(_call.leave());
    }
    if (_status != SwipeStatus.searching) _searchStartedAt = _now();
    _setStatus(SwipeStatus.searching);
    _sendJoin();
  }

  void _onMatchFound(MatchFound match) {
    final invited = _expectInvited;
    _expectInvited = false;
    if (invited && _canAdoptInvitedCall) {
      // Cuộc gọi lại bạn: vào thẳng, kể cả khi đang ở tab khác (HomeShell sẽ chuyển sang tab Lướt).
      _active = true;
      _permanentlyDenied = false;
    } else if (!_active || _status != SwipeStatus.searching) {
      // Không còn muốn cuộc gọi này: báo server dọn phòng.
      _ws.send('call.end', <String, dynamic>{'roomName': match.roomName});
      return;
    }
    _cancelAllTimers();
    _current = match;
    _currentIsContact = invited;
    _callQuality = CallQualityLevel.full;
    final qa = _call;
    if (qa is QualityAware) (qa as QualityAware).callProfile = invited ? CallProfile.friend : CallProfile.swipe;
    _micOn = true;
    _camOn = true;
    _hintForCurrent = false;
    _setStatus(SwipeStatus.connecting);
    _matchTimer = _timerFactory(matchTimeout, _onMatchTimeout);
    unawaited(_joinCall(match));
  }

  /// Có thể nhận cuộc gọi lại bạn ở trạng thái hiện tại không.
  bool get _canAdoptInvitedCall =>
      _status == SwipeStatus.searching ||
      // Quyền được cấp qua hộp thoại của lời mời (không qua nút trên màn Lướt): vẫn nhận cuộc gọi.
      _status == SwipeStatus.needsPermission ||
      _status == SwipeStatus.inactive ||
      _status == SwipeStatus.offline;

  Future<void> _joinCall(MatchFound match) async {
    try {
      await _call.joinMatch(match);
    } on Object catch (e) {
      debugPrint('call.join failed: $e');
      if (_current?.roomName == match.roomName) await next();
    }
  }

  void _onMatchTimeout() {
    _matchTimer = null;
    if (_status == SwipeStatus.connecting) unawaited(next());
  }

  Future<void> _onCallEnded(CallEnded m) async {
    // API.md §2.7 mục 7: bỏ qua call.ended của phòng khác.
    if (m.roomName != _current?.roomName) return;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _cancelCallTimers();
    final ended = _current;
    _current = null;
    if (_currentIsContact && ended != null) {
      // Cuộc gọi danh bạ không quay lại hàng chờ ngẫu nhiên, bất kể lý do kết thúc.
      _currentIsContact = false;
      _active = false;
      final shutdown = m.reason == CallEnded.serverShutdown;
      _setStatus(shutdown ? SwipeStatus.offline : SwipeStatus.inactive);
      await _call.leave();
      _emitContactEnd(
        ended.peer,
        byPeer: m.reason == CallEnded.peerLeft || m.reason == CallEnded.blocked,
        network: shutdown,
      );
      return;
    }
    switch (m.reason) {
      case CallEnded.youLeft:
        _notify();
      case CallEnded.youNext:
        _searchStartedAt = _now();
        _setStatus(SwipeStatus.searching);
      case CallEnded.serverShutdown:
        _setStatus(SwipeStatus.offline);
      case CallEnded.peerLeft:
      case CallEnded.blocked:
      default:
        _searchStartedAt = _now();
        _setStatus(SwipeStatus.searching);
        await _call.leave();
        if (_status == SwipeStatus.searching && _current == null) _sendJoin();
        return;
    }
    await _call.leave();
  }

  void _onServerError(ServerError e) {
    if (e.code == 'NOT_IN_CALL' && _resumeTimer != null) {
      // Server không còn giữ phòng (hết hạn/bạn đã cúp): kết thúc cuộc gọi.
      _endContactByNetwork();
      return;
    }
    switch (e.code) {
      case 'RATE_LIMITED':
        _addNotice(e.code);
        final wait = e.retryAfterSec == null
            ? defaultRateLimitRetry
            : Duration(seconds: e.retryAfterSec!);
        _scheduleRejoin(wait);
      case 'PROFILE_INCOMPLETE':
      case 'UNDERAGE':
      case 'ACCOUNT_BANNED':
      case 'UNAUTHENTICATED':
        unawaited(_refreshSession());
      case 'CALL_PROVIDER_ERROR':
        _addNotice(e.code);
        _scheduleRejoin(providerRetry);
      case 'SESSION_REPLACED':
        _cancelAllTimers();
        _resumeTimer?.cancel();
        _resumeTimer = null;
        _current = null;
        _blockedCode = e.code;
        unawaited(_call.leave());
        _addNotice(e.code);
        _setStatus(SwipeStatus.blockedPermanently);
      default:
        // NOT_IN_CALL, ALREADY_IN_CALL, BAD_MESSAGE...: vô hại, chỉ ghi log.
        debugPrint('ws error ignored: ${e.code}');
    }
  }

  void _onCallEvent(CallEvent e) {
    switch (e) {
      case RemoteVideoReady():
        if (_status != SwipeStatus.connecting) return;
        // Báo server "đã kết nối" để phân biệt cuộc gọi thật với cúp trước khi nối (chấm điểm quét IP phía server).
        final room = _current?.roomName;
        if (room != null) _ws.send('rtc.state', <String, dynamic>{'roomName': room, 'state': 'connected'});
        _matchTimer?.cancel();
        _matchTimer = null;
        _remoteLeftTimer?.cancel();
        _remoteLeftTimer = null;
        _hintForCurrent = _swipeHintsShown < maxSwipeHints;
        if (_hintForCurrent) _swipeHintsShown++;
        _setStatus(SwipeStatus.inCall);
      case PeerAnomaly(:final signals):
        _handlePeerAnomaly(signals);
      case CallQualityChanged(:final level, :final notice, :final path):
        _callQuality = level;
        if (path == CallPath.p2p && level == CallQualityLevel.full) _weakStreak = 0;
        final code = switch (notice) {
          CallNotice.relaySlow => 'CALL_RELAY_SLOW',
          CallNotice.relayVerySlow => 'CALL_RELAY_VERY_SLOW',
          CallNotice.p2pRestored => 'CALL_P2P_RESTORED',
          _ => null,
        };
        if (code != null) _addNotice(code);
        notifyListeners();
      case NetworkPoor():
        // Lướt ưu tiên P2P ổn định: đi đường dự phòng quá 10 s hoặc không nối được → bỏ cuộc gọi này, tìm người khác.
        // Liên tiếp maxWeakMatches lần thì dừng hẳn và yêu cầu đổi mạng. Cuộc gọi lại bạn không tính vào chuỗi này.
        if (_current != null && !_currentIsContact) {
          _weakStreak++;
          if (_weakStreak >= maxWeakMatches) {
            unawaited(_stopForWeakNetwork());
            return;
          }
          _addNotice('SWIPE_RELAY_SKIPPED');
          unawaited(next());
          return;
        }
        _addNotice('NETWORK_POOR');
        if (_current != null) unawaited(next());
      case CallReconnecting():
        // Đang tự nối lại: không coi là đối phương rời; hủy hẹn kết thúc đang chờ.
        _remoteLeftTimer?.cancel();
        _remoteLeftTimer = null;
        _addNotice('CALL_RECONNECTING');
      case CallReconnected():
        _addNotice('CALL_RECONNECTED');
      case RemoteLeft():
      case Disconnected():
        final room = _current?.roomName;
        if (room == null) return;
        _remoteLeftTimer?.cancel();
        _remoteLeftTimer = _timerFactory(remoteLeftGrace, () {
          _remoteLeftTimer = null;
          if (_current?.roomName == room) unawaited(next());
        });
    }
  }

  /// Dừng tìm người vì mạng yếu liên tiếp. `_active=false` để `activate()` (người dùng bấm thử lại / vào lại tab) bắt đầu lại và xóa chuỗi.
  Future<void> _stopForWeakNetwork() async {
    final cur = _current;
    _cancelAllTimers();
    _active = false;
    _current = null;
    _currentIsContact = false;
    _setStatus(SwipeStatus.weakNetwork);
    _addNotice('SWIPE_WEAK_STOPPED');
    await _call.leave();
    if (cur != null) _ws.send('call.end', <String, dynamic>{'roomName': cur.roomName});
  }

  /// Đối phương có dấu hiệu dò/thu hoạch IP (CHONG-QUET-IP-P2P.md, L3): cắt ngay, chặn, cảnh báo, báo server.
  /// Không qua `swipeDebounce`: an toàn phải được ưu tiên.
  void _handlePeerAnomaly(List<AbuseSignal> signals) {
    final cur = _current;
    if (cur == null) return;
    final wasContact = _currentIsContact;
    _cancelCallTimers();
    _ws.send('rtc.abuse', <String, dynamic>{
      'roomName': cur.roomName,
      'signals': <Map<String, dynamic>>[for (final s in signals) s.toJson()],
    });
    _addNotice('PEER_ANOMALY');
    _shield.recordIncident();
    final pause = _shield.pauseRemaining;
    if (pause > Duration.zero && !_currentIsContact) {
      // Lần thứ hai trong thời gian ngắn: rời hàng chờ một lúc để không bị "cày" liên tục.
      _current = null;
      _searchStartedAt = _now();
      _setStatus(SwipeStatus.searching);
      unawaited(_call.leave());
      _ws.send('call.end', <String, dynamic>{'roomName': cur.roomName});
      _addNotice('SHIELD_PAUSE');
      _scheduleRejoin(pause);
    } else {
      _lastNextAt = null;
      unawaited(next());
    }
    // Cuộc gọi với BẠN BÈ: chỉ cắt + báo, KHÔNG tự chặn (chặn sẽ xóa luôn quan hệ bạn bè).
    final block = autoBlock;
    if (block != null && !wasContact) {
      unawaited(block(cur.peer).catchError((Object e) => debugPrint('auto-block ignored: $e')));
    }
  }

  // --- tiện ích -------------------------------------------------------------------

  void _beginSearching() {
    _cancelAllTimers();
    _searchStartedAt = _now();
    _setStatus(SwipeStatus.searching);
    if (_ws.isConnected) {
      _wasConnected = true;
      _sendJoin();
    } else {
      // `queue.join` được gửi khi nhận `session.ready`.
      unawaited(_ws.connect());
    }
  }

  void _sendJoin() => _ws.send('queue.join');

  /// Hẹn gửi lại `queue.join` nếu vẫn đang tìm (sau RATE_LIMITED / CALL_PROVIDER_ERROR).
  void _scheduleRejoin(Duration wait) {
    _retryTimer?.cancel();
    _retryTimer = _timerFactory(wait, () {
      _retryTimer = null;
      if (_active && _status == SwipeStatus.searching && _current == null) _sendJoin();
    });
  }

  /// Thời gian chờ nối lại WebSocket để giữ cuộc gọi danh bạ (khớp ~15 s phía server).
  static const contactResumeWindow = Duration(seconds: 15);
  Timer? _resumeTimer;

  /// Hết thời gian chờ / server không giữ phòng: kết thúc cuộc gọi danh bạ do mất mạng.
  void _endContactByNetwork() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    final cur = _current;
    if (cur == null || !_currentIsContact) return;
    // TUYỆT ĐỐI không để `session.ready` sau này đẩy người dùng vào hàng chờ lướt ngẫu nhiên.
    _cancelAllTimers();
    _current = null;
    _currentIsContact = false;
    _active = false;
    _setStatus(SwipeStatus.inactive);
    unawaited(_call.leave());
    _addNotice('NETWORK');
    _emitContactEnd(cur.peer, byPeer: false, network: true);
  }

  void _goOffline() {
    if (!_active ||
        _status == SwipeStatus.blockedPermanently ||
        _status == SwipeStatus.needsPermission ||
        _status == SwipeStatus.inactive) {
      return;
    }
    _cancelAllTimers();
    final cur = _current;
    if (cur != null && _currentIsContact) {
      // Rớt WebSocket giữa cuộc gọi danh bạ: media P2P vẫn chạy, chờ nối lại và xin server giữ phòng (call.resume).
      _resumeTimer?.cancel();
      _resumeTimer = _timerFactory(contactResumeWindow, _endContactByNetwork);
      return;
    }
    if (cur != null) {
      _current = null;
      unawaited(_call.leave());
    }
    _setStatus(SwipeStatus.offline);
  }

  void _cancelCallTimers() {
    _matchTimer?.cancel();
    _matchTimer = null;
    _remoteLeftTimer?.cancel();
    _remoteLeftTimer = null;
  }

  void _cancelAllTimers() {
    _cancelCallTimers();
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _setStatus(SwipeStatus s) {
    _status = s;
    _notify();
  }

  void _emitContactEnd(Peer peer, {required bool byPeer, bool network = false}) {
    if (!_contactEnds.isClosed) _contactEnds.add(ContactCallEnd(peer: peer, byPeer: byPeer, network: network));
  }

  void _addNotice(String code) {
    if (!_notices.isClosed) _notices.add(code);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAllTimers();
    _resumeTimer?.cancel();
    _msgSub.cancel();
    _stateSub.cancel();
    _callSub.cancel();
    _notices.close();
    _contactEnds.close();
    super.dispose();
  }
}
