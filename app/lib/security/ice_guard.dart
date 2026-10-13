import 'dart:collection';

/// Chống quét / thu hoạch IP trong cuộc gọi P2P – xem CHONG-QUET-IP-P2P.md.
///
/// Mô-đun THUẦN Dart (không socket, không đĩa, không log IP):
///  - L0 lọc ứng viên ICE chiều gửi ([IceGuard.sanitizeOutgoing]) và chiều nhận ([IceGuard.checkIncoming]);
///  - L2 chấm điểm bất thường từ tín hiệu ứng viên và `getStats()` ([IceGuard.onStats]).
/// Điểm tích lũy theo MỖI cuộc gọi; ≥ [anomalyThreshold] = bất thường.

/// Mã dấu hiệu + điểm (khớp bảng ở mục 4/L2 của tài liệu).
enum AbuseCode {
  candPrivate('cand_private', 5),
  candMalformed('cand_malformed', 2),
  candFlood('cand_flood', 5),
  candPorts('cand_ports', 3),
  prflxUnknown('prflx_unknown', 3),
  stunUnsolicited('stun_unsolicited', 4),
  iceOnlyProbe('ice_only_probe', 2),
  signalReplay('signal_replay', 2);

  const AbuseCode(this.code, this.points);
  final String code;
  final int points;
}

/// Một dấu hiệu đã ghi nhận (chỉ mã + số lần; KHÔNG chứa IP).
class AbuseSignal {
  const AbuseSignal(this.code, this.count);
  final String code;
  final int count;

  Map<String, dynamic> toJson() => <String, dynamic>{'code': code, 'count': count};

  @override
  String toString() => '$code×$count';
}

/// Một báo cáo thống kê rút gọn từ `RTCPeerConnection.getStats()` (tách khỏi flutter_webrtc để test được).
class StatReport {
  const StatReport(this.type, this.values);
  final String type;
  final Map<String, dynamic> values;
}

enum IncomingVerdict { accept, drop }

enum AddrKind { v4, v6, mdns, invalid }

/// Ứng viên ICE đã phân tích. Dòng gốc ở [raw].
class IceCandidateInfo {
  const IceCandidateInfo._({
    required this.raw,
    required this.tokens,
    required this.transport,
    required this.address,
    required this.port,
    required this.type,
    required this.addrKind,
    required this.tcpType,
  });

  final String raw;
  final List<String> tokens;
  final String transport; // udp | tcp (chữ thường)
  final String address;
  final int port;
  final String type; // host | srflx | prflx | relay
  final AddrKind addrKind;
  final String? tcpType;

  /// Phân tích `candidate:...` hoặc `a=candidate:...`. `null` nếu sai cú pháp.
  static IceCandidateInfo? tryParse(String? line) {
    if (line == null) return null;
    final s = line.trim();
    if (s.isEmpty || s.length > 512) return null;
    final t = s.split(RegExp(r'\s+'));
    if (t.length < 8) return null;
    if (!(t[0].startsWith('candidate:') || t[0].startsWith('a=candidate:'))) return null;
    if (t[6] != 'typ') return null;
    final component = int.tryParse(t[1]);
    final priority = int.tryParse(t[3]);
    final port = int.tryParse(t[5]);
    if (component == null || priority == null || port == null) return null;
    if (component < 1 || component > 2) return null;
    final transport = t[2].toLowerCase();
    if (transport != 'udp' && transport != 'tcp') return null;
    final type = t[7].toLowerCase();
    if (type != 'host' && type != 'srflx' && type != 'prflx' && type != 'relay') return null;
    String? tcpType;
    for (var i = 8; i + 1 < t.length; i++) {
      if (t[i] == 'tcptype') tcpType = t[i + 1].toLowerCase();
    }
    final address = t[4];
    return IceCandidateInfo._(
      raw: s,
      tokens: t,
      transport: transport,
      address: address,
      port: port,
      type: type,
      addrKind: classifyAddress(address),
      tcpType: tcpType,
    );
  }

  /// Bản sao với `raddr`/`rport` bị che (địa chỉ liên quan có thể làm lộ IP nội bộ hoặc IP thật sau relay).
  String withRelatedHidden() {
    final t = List<String>.of(tokens);
    for (var i = 8; i + 1 < t.length; i++) {
      if (t[i] == 'raddr') {
        t[i + 1] = classifyAddress(t[i + 1]) == AddrKind.v6 ? '::' : '0.0.0.0';
      } else if (t[i] == 'rport') {
        t[i + 1] = '0';
      }
    }
    return t.join(' ');
  }
}

// --- địa chỉ ------------------------------------------------------------------------

final RegExp _digits = RegExp(r'^\d+$');
final RegExp _mdnsName = RegExp(r'^[A-Za-z0-9\-]{1,64}\.local$');

List<int>? parseIPv4(String s) {
  final p = s.split('.');
  if (p.length != 4) return null;
  final out = <int>[];
  for (final x in p) {
    if (x.isEmpty || x.length > 3 || !_digits.hasMatch(x)) return null;
    final n = int.parse(x);
    if (n > 255) return null;
    out.add(n);
  }
  return out;
}

/// 8 nhóm 16 bit, hoặc `null` nếu sai cú pháp.
List<int>? parseIPv6(String input) {
  var str = input;
  final pct = str.indexOf('%');
  if (pct >= 0) str = str.substring(0, pct);
  if (str.isEmpty || !str.contains(':')) return null;
  List<int>? tail4;
  final lastColon = str.lastIndexOf(':');
  final lastPart = str.substring(lastColon + 1);
  if (lastPart.contains('.')) {
    final v4 = parseIPv4(lastPart);
    if (v4 == null) return null;
    tail4 = <int>[(v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]];
    str = '${str.substring(0, lastColon + 1)}0:0';
  }
  final dbl = str.indexOf('::');
  if (dbl != str.lastIndexOf('::')) return null;
  List<String> head;
  List<String> tail;
  if (dbl >= 0) {
    final h = str.substring(0, dbl);
    final t = str.substring(dbl + 2);
    head = h.isEmpty ? <String>[] : h.split(':');
    tail = t.isEmpty ? <String>[] : t.split(':');
    if (head.length + tail.length > 7) return null;
  } else {
    head = str.split(':');
    tail = <String>[];
    if (head.length != 8) return null;
  }
  int? grp(String x) {
    if (x.isEmpty || x.length > 4) return null;
    return int.tryParse(x, radix: 16);
  }

  final groups = <int>[];
  for (final x in head) {
    final v = grp(x);
    if (v == null) return null;
    groups.add(v);
  }
  final fill = 8 - head.length - tail.length;
  for (var i = 0; i < fill; i++) {
    groups.add(0);
  }
  for (final x in tail) {
    final v = grp(x);
    if (v == null) return null;
    groups.add(v);
  }
  if (groups.length != 8) return null;
  if (tail4 != null) {
    groups[6] = tail4[0];
    groups[7] = tail4[1];
  }
  return groups;
}

AddrKind classifyAddress(String a) {
  if (parseIPv4(a) != null) return AddrKind.v4;
  if (a.contains(':')) return parseIPv6(a) != null ? AddrKind.v6 : AddrKind.invalid;
  if (_mdnsName.hasMatch(a)) return AddrKind.mdns;
  return AddrKind.invalid;
}

bool _nonPublicV4(List<int> v) {
  final a = v[0], b = v[1], c = v[2];
  if (a == 0 || a == 10 || a == 127 || a >= 224) return true;
  if (a == 169 && b == 254) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  if (a == 100 && (b & 0xC0) == 0x40) return true; // 100.64.0.0/10 (CGNAT)
  if (a == 192 && b == 0 && c == 0) return true;
  if (a == 192 && b == 0 && c == 2) return true;
  if (a == 198 && (b == 18 || b == 19)) return true;
  if (a == 198 && b == 51 && c == 100) return true;
  if (a == 203 && b == 0 && c == 113) return true;
  return false;
}

bool _nonPublicV6(List<int> g) {
  final allZeroTo5 = g[0] == 0 && g[1] == 0 && g[2] == 0 && g[3] == 0 && g[4] == 0 && g[5] == 0;
  if (allZeroTo5 && g[6] == 0 && g[7] <= 1) return true; // :: và ::1
  if (allZeroTo5) return true; // ::/96 tương thích IPv4 (lỗi thời)
  if (g[0] == 0 && g[1] == 0 && g[2] == 0 && g[3] == 0 && g[4] == 0 && g[5] == 0xFFFF) {
    return _nonPublicV4(<int>[g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255]);
  }
  if ((g[0] & 0xFE00) == 0xFC00) return true; // fc00::/7
  if ((g[0] & 0xFFC0) == 0xFE80) return true; // fe80::/10
  if ((g[0] & 0xFFC0) == 0xFEC0) return true; // fec0::/10
  if ((g[0] >> 8) == 0xFF) return true; // ff00::/8
  if (g[0] == 0x2001 && g[1] == 0x0DB8) return true; // tài liệu
  if (g[0] == 0x0100 && g[1] == 0 && g[2] == 0 && g[3] == 0) return true; // 100::/64
  return false;
}

/// `true` nếu địa chỉ KHÔNG phải IP công khai định tuyến được (riêng tư, loopback, link-local, multicast, dành riêng).
/// Địa chỉ sai cú pháp hoặc mDNS trả `false` (xử lý riêng theo [AddrKind]).
bool isNonPublicAddress(String address) {
  final v4 = parseIPv4(address);
  if (v4 != null) return _nonPublicV4(v4);
  final v6 = address.contains(':') ? parseIPv6(address) : null;
  if (v6 != null) return _nonPublicV6(v6);
  return false;
}

// --- IceGuard ---------------------------------------------------------------------

class IceGuard {
  IceGuard({
    DateTime Function()? now,
    this.strictIpv6 = false,
    this.maxCandidates = 16,
    this.maxPerSecond = 20,
  }) : _now = now ?? DateTime.now;

  /// Điểm từ ngưỡng này trở lên = bất thường.
  static const int anomalyThreshold = 5;

  /// Cổng thấp nhưng hợp lệ (STUN/TURN).
  static const Set<int> allowedLowPorts = <int>{3478, 5349};

  final DateTime Function() _now;

  /// Không gửi ứng viên `host` IPv6 toàn cục (IPv6 không có NAT che).
  final bool strictIpv6;
  final int maxCandidates;
  final int maxPerSecond;

  final Map<AbuseCode, int> _counts = <AbuseCode, int>{};
  int _score = 0;

  int _incomingTotal = 0;
  final Queue<DateTime> _recent = Queue<DateTime>();
  final Set<String> _knownRemote = <String>{};
  final Map<String, Set<int>> _portsByAddr = <String, Set<int>>{};
  final Set<String> _unknownPrflx = <String>{};
  DateTime? _iceConnectedAt;
  bool _media = false;

  int get score => _score;
  bool get anomaly => _score >= anomalyThreshold;

  List<AbuseSignal> get signals => <AbuseSignal>[
        for (final e in _counts.entries) AbuseSignal(e.key.code, e.value),
      ];

  void _record(AbuseCode c, {bool once = false}) {
    final had = _counts[c] ?? 0;
    if (once && had > 0) return;
    _counts[c] = had + 1;
    _score += c.points;
  }

  // --- L0: chiều gửi ---------------------------------------------------------------

  /// Trả dòng ứng viên đã làm sạch để gửi đi, hoặc `null` nếu KHÔNG được gửi.
  String? sanitizeOutgoing(String line, {required bool relayOnly}) {
    final c = IceCandidateInfo.tryParse(line);
    if (c == null) return null;
    if (relayOnly && c.type != 'relay') return null;
    switch (c.type) {
      case 'relay':
        break;
      case 'srflx':
        if (c.transport != 'udp') return null;
        if (c.addrKind == AddrKind.invalid || isNonPublicAddress(c.address)) return null;
      case 'host':
        if (c.transport != 'udp') return null;
        if (c.addrKind == AddrKind.invalid) return null;
        if (c.addrKind != AddrKind.mdns) {
          if (isNonPublicAddress(c.address)) return null; // không đưa IP LAN cho người lạ
          if (strictIpv6 && c.addrKind == AddrKind.v6) return null;
        }
      default:
        return null; // prflx không bao giờ do ta gửi
    }
    return c.withRelatedHidden();
  }

  /// Làm sạch SDP. Chiều gửi: bỏ/ che các dòng `a=candidate`. Chiều nhận: kiểm từng dòng qua [checkIncoming].
  String sanitizeSdp(String sdp, {required bool outgoing, bool relayOnly = false}) {
    if (!sdp.contains('a=candidate:')) return sdp;
    final nl = sdp.contains('\r\n') ? '\r\n' : '\n';
    final out = <String>[];
    for (final l in sdp.split(nl)) {
      if (!l.startsWith('a=candidate:')) {
        out.add(l);
        continue;
      }
      if (outgoing) {
        final s = sanitizeOutgoing(l, relayOnly: relayOnly);
        if (s != null) out.add(s);
      } else if (checkIncoming(l) == IncomingVerdict.accept) {
        out.add(l);
      }
    }
    return out.join(nl);
  }

  // --- L0: chiều nhận --------------------------------------------------------------

  IncomingVerdict checkIncoming(String? line) {
    _incomingTotal++;
    final t = _now();
    _recent.addLast(t);
    while (_recent.isNotEmpty && t.difference(_recent.first) > const Duration(seconds: 1)) {
      _recent.removeFirst();
    }
    if (_incomingTotal > maxCandidates || _recent.length > maxPerSecond) {
      _record(AbuseCode.candFlood, once: true);
      return IncomingVerdict.drop;
    }
    final c = IceCandidateInfo.tryParse(line);
    if (c == null) {
      _record(AbuseCode.candMalformed);
      return IncomingVerdict.drop;
    }
    if (c.addrKind == AddrKind.invalid) {
      _record(AbuseCode.candMalformed);
      return IncomingVerdict.drop;
    }
    if (c.addrKind == AddrKind.mdns) {
      return IncomingVerdict.drop; // không phân giải mDNS do người lạ đưa; ứng viên srflx sẽ thay thế
    }
    if (isNonPublicAddress(c.address)) {
      _record(AbuseCode.candPrivate);
      return IncomingVerdict.drop;
    }
    if (c.port <= 0 || c.port > 65535) {
      _record(AbuseCode.candMalformed);
      return IncomingVerdict.drop;
    }
    if (c.port < 1024 && !allowedLowPorts.contains(c.port)) {
      _record(AbuseCode.candPorts);
      return IncomingVerdict.drop;
    }
    if (c.type == 'prflx') {
      _record(AbuseCode.signalReplay); // đối phương không được tự báo prflx qua tín hiệu
      return IncomingVerdict.drop;
    }
    if (c.transport != 'udp' && c.type != 'relay') {
      return IncomingVerdict.drop; // không chủ động mở TCP tới người lạ
    }
    final ports = _portsByAddr.putIfAbsent(c.address, () => <int>{});
    ports.add(c.port);
    if (ports.length >= 6 || _portsByAddr.length > 8) {
      _record(AbuseCode.candPorts, once: true);
    }
    _knownRemote.add(c.address);
    return IncomingVerdict.accept;
  }

  /// Tín hiệu lặp / sai thứ tự (ví dụ `rtc.signal` sau `bye`).
  void noteSignalReplay() => _record(AbuseCode.signalReplay);

  // --- L2: thống kê & thời gian -----------------------------------------------------

  void noteIceConnected() => _iceConnectedAt ??= _now();

  void noteMedia() => _media = true;

  /// Đối phương cúp: nếu ngay sau khi ICE nối (< 3 s) thì là dấu hiệu "chỉ lấy IP" (điểm nhẹ).
  void noteRemoteLeft() {
    final at = _iceConnectedAt;
    if (at != null && !_media && _now().difference(at) < const Duration(seconds: 3)) {
      _record(AbuseCode.iceOnlyProbe, once: true);
    }
  }

  /// Gọi định kỳ cùng với [onStats].
  void tick() {
    final at = _iceConnectedAt;
    if (at != null && !_media && _now().difference(at) > const Duration(seconds: 5)) {
      _record(AbuseCode.iceOnlyProbe, once: true);
    }
  }

  static num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  void onStats(Iterable<StatReport> reports) {
    var unsolicited = 0;
    for (final r in reports) {
      switch (r.type) {
        case 'remote-candidate':
          final kind = '${r.values['candidateType'] ?? ''}'.toLowerCase();
          final addr = '${r.values['address'] ?? r.values['ip'] ?? ''}';
          if (kind == 'prflx' && addr.isNotEmpty && !_knownRemote.contains(addr)) {
            // Một địa chỉ prflx lạ là bình thường (NAT đối xứng); từ địa chỉ thứ hai trở đi mới đáng ngờ.
            if (_unknownPrflx.add(addr) && _unknownPrflx.length >= 2) {
              _record(AbuseCode.prflxUnknown);
            }
          }
        case 'candidate-pair':
          final nominated = r.values['nominated'] == true || '${r.values['nominated']}' == 'true';
          if (!nominated) {
            unsolicited += (_num(r.values['requestsReceived']) ?? 0).toInt();
          }
      }
    }
    if (unsolicited > 50) _record(AbuseCode.stunUnsolicited, once: true);
  }
}
