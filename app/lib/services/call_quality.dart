/// Đường truyền thực tế của cuộc gọi (theo cặp ứng viên ICE đang được dùng).
enum CallPath { unknown, p2p, relay }

/// Mức chất lượng gửi đi của máy mình.
enum CallQualityLevel { full, low, audioOnly }

/// Loại cuộc gọi: bạn bè (gọi lại, kiên nhẫn hơn) hoặc lướt ngẫu nhiên (ngắn, tiết kiệm relay).
enum CallProfile { friend, swipe }

/// Thông báo trung thực cho người dùng (không giấu việc đang dùng đường dự phòng chất lượng thấp).
enum CallNotice { relaySlow, relayVerySlow, weakEnded, p2pRestored }

/// Mốc thời gian + giới hạn băng thông. Mọi con số ở một chỗ để chỉnh/ghi đè khi cần.
class CallQualityConfig {
  const CallQualityConfig({
    this.friendSlow = const Duration(seconds: 10),
    this.friendAudioOnly = const Duration(seconds: 20),
    this.friendEnd = const Duration(seconds: 30),
    this.swipeEnd = const Duration(seconds: 10),
    this.lowVideoKbps = 200,
    this.lowAudioKbps = 24,
    this.fullVideoKbps = 900,
    this.lowFps = 12,
    this.lowScaleDown = 2.0,
    this.p2pRetryEvery = const Duration(seconds: 8),
    this.swipeStableTicks = 2,
  });

  /// Gọi bạn: sau mốc này báo "mạng chậm" nếu vẫn chưa có P2P.
  final Duration friendSlow;

  /// Gọi bạn: sau mốc này báo "quá chậm" và chỉ còn tiếng.
  final Duration friendAudioOnly;

  /// Gọi bạn: sau mốc này báo mạng yếu và dừng cuộc gọi.
  final Duration friendEnd;

  /// Lướt: cửa sổ relay tối đa; hết cửa sổ thì báo và chuyển người khác.
  final Duration swipeEnd;

  final int lowVideoKbps;
  final int lowAudioKbps;
  final int fullVideoKbps;
  final int lowFps;
  final double lowScaleDown;

  /// Khi đang đi qua relay, cứ chừng này lại thử dò lại đường P2P (ICE restart).
  final Duration p2pRetryEvery;

  /// Lướt: P2P phải giữ liên tiếp chừng này lần đo (≈ giây) mới coi là ỔN ĐỊNH; thoáng qua thì vẫn tính là chưa có P2P.
  /// Gọi bạn luôn coi P2P là ổn định ngay (1).
  final int swipeStableTicks;
}

/// Kết quả một lần đánh giá.
class QualityDecision {
  const QualityDecision({
    required this.level,
    this.notice,
    this.endCall = false,
    this.retryP2p = false,
  });

  final CallQualityLevel level;

  /// Thông báo mới cần hiện (mỗi loại chỉ phát một lần mỗi đợt relay).
  final CallNotice? notice;

  /// Dừng cuộc gọi vì mạng quá yếu.
  final bool endCall;

  /// Nên thử dò lại P2P ngay bây giờ.
  final bool retryP2p;
}

/// Bộ điều phối thuần (không phụ thuộc WebRTC, không đồng hồ ngầm) nên kiểm thử được.
///
/// Quy tắc (xem PHAN-TICH-GOI-DIEN-TURN.md):
/// - Đang P2P: chất lượng đầy đủ, TURN không mang dữ liệu; về P2P sau một đợt relay thì báo "đã khôi phục".
/// - Đang relay hoặc chưa nối: giới hạn chất lượng thấp; đếm thời gian từ lúc bắt đầu đợt này.
///   Gọi bạn: 10 s báo chậm, 20 s chỉ còn tiếng, 30 s báo mạng yếu và dừng.
///   Lướt: 10 s báo mạng yếu và dừng (chuyển người khác).
class RelayGovernor {
  RelayGovernor({required this.profile, this.config = const CallQualityConfig()});

  final CallProfile profile;
  final CallQualityConfig config;

  Duration? _episodeStart; // lúc bắt đầu đợt "chưa có P2P"
  bool _slowSent = false;
  bool _verySlowSent = false;
  bool _endSent = false;
  bool _wasRelay = false;
  int _p2pRun = 0;
  bool _hadP2p = false; // đã từng có P2P: đợt relay sau đó tính từ lúc rơi xuống relay, không phải từ đầu cuộc gọi
  Duration _lastRetry = Duration.zero;

  /// Mốc thời gian đã trôi qua trong đợt hiện tại (để test/ghi log).
  Duration? get episodeStart => _episodeStart;

  void reset() {
    _episodeStart = null;
    _slowSent = false;
    _verySlowSent = false;
    _endSent = false;
    _wasRelay = false;
    _hadP2p = false;
    _p2pRun = 0;
    _lastRetry = Duration.zero;
  }

  /// [now]: đồng hồ đơn điệu tính từ lúc bắt đầu cuộc gọi; [path]: đường hiện tại.
  QualityDecision evaluate({required Duration now, required CallPath path}) {
    if (path == CallPath.p2p) {
      _p2pRun++;
      final need = profile == CallProfile.swipe ? config.swipeStableTicks : 1;
      if (_p2pRun < need) path = CallPath.unknown; // P2P chưa đủ ổn định: chưa tính
    } else {
      _p2pRun = 0;
    }
    if (path == CallPath.p2p) {
      final restored = _wasRelay;
      _episodeStart = null;
      _slowSent = _verySlowSent = _endSent = false;
      _wasRelay = false;
      _hadP2p = true;
      _lastRetry = Duration.zero;
      return QualityDecision(level: CallQualityLevel.full, notice: restored ? CallNotice.p2pRestored : null);
    }
    _episodeStart ??= _hadP2p ? now : Duration.zero;
    if (path == CallPath.relay) _wasRelay = true;
    final t = now - _episodeStart!;
    final isFriend = profile == CallProfile.friend;
    final endAt = isFriend ? config.friendEnd : config.swipeEnd;

    if (_endSent) return const QualityDecision(level: CallQualityLevel.audioOnly, endCall: true);
    if (t >= endAt) {
      _endSent = true;
      return const QualityDecision(level: CallQualityLevel.audioOnly, notice: CallNotice.weakEnded, endCall: true);
    }

    var level = CallQualityLevel.low;
    CallNotice? notice;
    if (isFriend) {
      if (t >= config.friendAudioOnly) {
        level = CallQualityLevel.audioOnly;
        if (!_verySlowSent) {
          _verySlowSent = true;
          _slowSent = true;
          notice = CallNotice.relayVerySlow;
        }
      } else if (t >= config.friendSlow && !_slowSent) {
        _slowSent = true;
        notice = CallNotice.relaySlow;
      }
    }

    var retry = false;
    if (path == CallPath.relay && t - _lastRetry >= config.p2pRetryEvery && t > Duration.zero) {
      _lastRetry = t;
      retry = true;
    }
    return QualityDecision(level: level, notice: notice, retryP2p: retry);
  }
}

/// Giới hạn gửi tương ứng một mức chất lượng (dùng cho `RTCRtpSender.setParameters`).
class SenderLimits {
  const SenderLimits({required this.videoActive, required this.videoMaxBitrate, required this.scaleDown, required this.maxFps, required this.audioMaxBitrate});

  final bool videoActive;
  final int videoMaxBitrate; // bit/s
  final double scaleDown;
  final int maxFps;
  final int audioMaxBitrate; // bit/s

  static SenderLimits forLevel(CallQualityLevel level, CallQualityConfig c) {
    switch (level) {
      case CallQualityLevel.full:
        return SenderLimits(videoActive: true, videoMaxBitrate: c.fullVideoKbps * 1000, scaleDown: 1.0, maxFps: 24, audioMaxBitrate: 40000);
      case CallQualityLevel.low:
        return SenderLimits(videoActive: true, videoMaxBitrate: c.lowVideoKbps * 1000, scaleDown: c.lowScaleDown, maxFps: c.lowFps, audioMaxBitrate: c.lowAudioKbps * 1000);
      case CallQualityLevel.audioOnly:
        return SenderLimits(videoActive: false, videoMaxBitrate: 0, scaleDown: c.lowScaleDown, maxFps: c.lowFps, audioMaxBitrate: c.lowAudioKbps * 1000);
    }
  }

  /// Ước lượng băng thông relay (bit/s) theo mức — để ghi tài liệu/kiểm tra.
  static int approxBitsPerSecond(CallQualityLevel level, CallQualityConfig c) {
    final l = forLevel(level, c);
    return (l.videoActive ? l.videoMaxBitrate : 0) + l.audioMaxBitrate;
  }
}

/// Một báo cáo thống kê rút gọn (id + loại + giá trị) từ `RTCPeerConnection.getStats`.
class PathStat {
  const PathStat(this.id, this.type, this.values);
  final String id;
  final String type;
  final Map<String, dynamic> values;
}

bool _truthy(Object? v) => v == true || v == 'true' || v == 1 || v == '1';

/// Xác định đường truyền đang dùng từ thống kê ICE.
/// Ưu tiên: `transport.selectedCandidatePairId` → cặp được chọn. Dự phòng: cặp `nominated`+`succeeded`
/// (hoặc `selected`/`googActiveConnection`). Relay nếu ứng viên nội bộ HOẶC ứng viên đối phương là `relay`.
CallPath pathFromStats(List<PathStat> stats) {
  final byId = <String, PathStat>{for (final s in stats) s.id: s};
  PathStat? pair;
  for (final s in stats) {
    if (s.type == 'transport') {
      final id = s.values['selectedCandidatePairId'];
      if (id is String && byId[id] != null) pair = byId[id];
    }
  }
  pair ??= () {
    for (final s in stats) {
      if (s.type != 'candidate-pair') continue;
      final state = '${s.values['state'] ?? ''}'.toLowerCase();
      final active = _truthy(s.values['selected']) ||
          _truthy(s.values['googActiveConnection']) ||
          (_truthy(s.values['nominated']) && (state == 'succeeded' || state == ''));
      if (active) return s;
    }
    return null;
  }();
  if (pair == null) return CallPath.unknown;
  String typeOf(Object? cid) {
    final c = cid is String ? byId[cid] : null;
    return '${c?.values['candidateType'] ?? ''}'.toLowerCase();
  }

  final local = typeOf(pair.values['localCandidateId']);
  final remote = typeOf(pair.values['remoteCandidateId']);
  if (local.isEmpty && remote.isEmpty) return CallPath.unknown;
  if (local == 'relay' || remote == 'relay') return CallPath.relay;
  return CallPath.p2p;
}

/// Có cặp P2P (không relay) đã `succeeded` nhưng chưa được chọn không? (dùng để quyết định thử lại P2P)
bool hasSucceededDirectPair(List<PathStat> stats) {
  final byId = <String, PathStat>{for (final s in stats) s.id: s};
  for (final s in stats) {
    if (s.type != 'candidate-pair' || '${s.values['state'] ?? ''}'.toLowerCase() != 'succeeded') continue;
    String typeOf(Object? cid) => '${(cid is String ? byId[cid] : null)?.values['candidateType'] ?? ''}'.toLowerCase();
    final l = typeOf(s.values['localCandidateId']);
    final r = typeOf(s.values['remoteCandidateId']);
    if (l.isNotEmpty && r.isNotEmpty && l != 'relay' && r != 'relay') return true;
  }
  return false;
}
