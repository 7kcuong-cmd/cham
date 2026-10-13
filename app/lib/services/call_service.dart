import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../models/match_found.dart';
import 'call_quality.dart';
import '../security/ice_guard.dart';
import '../theme/tokens.dart';

/// Sự kiện từ phòng gọi (độc lập với SDK để SwipeController test được).
sealed class CallEvent {
  const CallEvent();
}

/// Đã thấy track video của đối phương.
final class RemoteVideoReady extends CallEvent {
  const RemoteVideoReady();
}

/// Đối phương rời phòng (LiveKit báo trước server).
final class RemoteLeft extends CallEvent {
  const RemoteLeft();
}

/// Mình bị ngắt khỏi phòng ngoài ý muốn (mạng, server). KHÔNG phát khi chính
/// mình gọi [CallService.leave].
final class Disconnected extends CallEvent {
  const Disconnected();
}

/// Không nối được cuộc gọi bằng cả P2P lẫn LiveKit: nên gợi ý người dùng đổi mạng (Wi‑Fi ↔ 4G).
final class NetworkPoor extends CallEvent {
  const NetworkPoor();
}

/// Chất lượng/đường truyền đổi (P2P ↔ relay TURN) hoặc có thông báo cần cho người dùng thấy.
final class CallQualityChanged extends CallEvent {
  const CallQualityChanged({required this.level, required this.path, this.notice});
  final CallQualityLevel level;
  final CallPath path;

  /// Thông báo mới (mỗi loại phát một lần mỗi đợt relay); null = chỉ đổi trạng thái.
  final CallNotice? notice;
}

/// Mạng ngắt/chập chờn giữa cuộc gọi: dịch vụ đang tự nối lại (giữ phòng); chưa phải kết thúc.
final class CallReconnecting extends CallEvent {
  const CallReconnecting();
}

/// Đã nối lại được sau [CallReconnecting].
final class CallReconnected extends CallEvent {
  const CallReconnected();
}

/// Đối phương có dấu hiệu dò/thu hoạch IP (xem [IceGuard]): nên cắt cuộc gọi, chặn và cảnh báo.
final class PeerAnomaly extends CallEvent {
  const PeerAnomaly(this.signals);
  final List<AbuseSignal> signals;
}

/// Chụp một khung từ camera của mình (PNG/JPEG) cho mặt lạ. Tách khỏi [CallService] vì các bản giả trong test
/// `implements CallService`; nơi dùng kiểm bằng `is FrameCapturable`.
abstract interface class FrameCapturable {
  Future<Uint8List?> captureLocalFrame();

  /// Khung hình của ĐỐI PHƯƠNG (làm mờ mặt họ trong clip khi mình ghi hình).
  Future<Uint8List?> captureRemoteFrame();
}

/// Kênh nhị phân P2P (DataChannel `media`) cho "xem/nghe chung". Tách khỏi [CallService] vì các bản giả
/// trong test `implements CallService`; nơi dùng kiểm bằng `is BinaryChannel`.
abstract interface class BinaryChannel {
  /// Mỗi phần tử là một khung nhị phân đã nhận.
  Stream<Uint8List> get binaryMessages;

  /// Kênh đã mở và dùng được (chỉ khi gọi P2P trực tiếp).
  bool get binaryOpen;

  /// Gửi một khung; false nếu kênh chưa mở.
  bool sendBinary(Uint8List data);

  /// Số byte đang xếp hàng chờ gửi (để bên gửi giãn nhịp).
  int get binaryBuffered;
}

/// Dịch vụ gọi biết áp dụng mốc thời gian/giới hạn chất lượng khi đi qua relay. Tách riêng để các bản giả trong test
/// (`implements CallService`) không phải cài thêm; nơi dùng kiểm bằng `is QualityAware`.
abstract interface class QualityAware {
  /// Gọi bạn (kiên nhẫn: 10/20/30 s) hay lướt (relay tối đa 10 s). Đặt TRƯỚC `joinMatch`.
  set callProfile(CallProfile profile);
}

abstract class CallService {
  /// Kết nối phòng rồi bật camera + mic.
  Future<void> join(String url, String token);

  /// Vào cuộc gọi theo `match.found`. Mặc định dùng LiveKit (url + token); bản P2P ghi đè.
  Future<void> joinMatch(MatchFound match) => join(match.livekitUrl, match.token);

  /// Kênh dữ liệu P2P (DataChannel) – chỉ có khi gọi trực tiếp. Mỗi tin là một JSON object.
  Stream<Map<String, dynamic>> get dataMessages => const Stream<Map<String, dynamic>>.empty();

  /// Gửi một tin qua DataChannel; false nếu kênh chưa mở / không hỗ trợ.
  bool sendData(Map<String, dynamic> message) => false;

  /// Rời phòng. Idempotent.
  Future<void> leave();

  Stream<CallEvent> get events;

  /// Video đối phương (cover, lấp đầy vùng cha).
  Widget remoteView();

  /// Video của mình (đã lật gương).
  Widget localView();

  Future<void> setMicEnabled(bool on);
  Future<void> setCameraEnabled(bool on);
  Future<void> switchCamera();
  Future<void> dispose();
}

/// Bản cài bằng `livekit_client` 2.x.
///
/// CẦN KIỂM TRA THEO PHIÊN BẢN (chưa biên dịch với SDK thật khi viết): tên lớp
/// `Room`, `RoomOptions`, `EventsListener`, `TrackSubscribedEvent`,
/// `ParticipantDisconnectedEvent`, `RoomDisconnectedEvent`,
/// `LocalTrackPublishedEvent`, `VideoTrackRenderer`, `VideoViewFit`,
/// `VideoViewMirrorMode`, `LocalVideoTrack.setCameraPosition`,
/// `Room.remoteParticipants`. Tài liệu: https://docs.livekit.io/reference/client-sdk-flutter/
class LiveKitCallService implements CallService {
  final StreamController<CallEvent> _events = StreamController<CallEvent>.broadcast();
  final ValueNotifier<lk.VideoTrack?> _remote = ValueNotifier<lk.VideoTrack?>(null);
  final ValueNotifier<lk.VideoTrack?> _local = ValueNotifier<lk.VideoTrack?>(null);

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;

  /// Tăng mỗi lần join/leave; dùng để bỏ kết quả của một `join` đã bị hủy.
  int _epoch = 0;
  bool _frontCamera = true;
  bool _remoteReadySent = false;

  @override
  Stream<CallEvent> get events => _events.stream;

  // `implements` không thừa kế phần cài sẵn của CallService nên phải khai báo lại.
  @override
  Future<void> joinMatch(MatchFound match) => join(match.livekitUrl, match.token);

  @override
  Stream<Map<String, dynamic>> get dataMessages => const Stream<Map<String, dynamic>>.empty();

  @override
  bool sendData(Map<String, dynamic> message) => false;

  @override
  Future<void> join(String url, String token) async {
    await leave();
    final epoch = ++_epoch;
    _remoteReadySent = false;
    _frontCamera = true;

    final room = lk.Room(
      roomOptions: const lk.RoomOptions(adaptiveStream: true, dynacast: true),
    );
    final listener = room.createListener();
    _room = room;
    _listener = listener;

    listener
      ..on<lk.TrackSubscribedEvent>((e) {
        if (epoch != _epoch) return;
        _onRemoteTrack(e.track);
      })
      ..on<lk.ParticipantDisconnectedEvent>((e) {
        if (epoch != _epoch) return;
        _remote.value = null;
        _events.add(const RemoteLeft());
      })
      ..on<lk.RoomDisconnectedEvent>((e) {
        if (epoch != _epoch) return;
        _events.add(const Disconnected());
      })
      ..on<lk.LocalTrackPublishedEvent>((e) {
        if (epoch != _epoch) return;
        _refreshLocalTrack(room);
      });

    try {
      await room.connect(url, token);
      if (epoch != _epoch) return; // leave() đã dọn phòng này
      for (final participant in room.remoteParticipants.values) {
        for (final pub in participant.videoTrackPublications) {
          _onRemoteTrack(pub.track);
        }
      }
      await room.localParticipant?.setCameraEnabled(true);
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (epoch != _epoch) return;
      _refreshLocalTrack(room);
    } on Object {
      if (epoch != _epoch) return; // lỗi do bị hủy giữa chừng
      rethrow;
    }
  }

  void _onRemoteTrack(Object? track) {
    if (track is! lk.VideoTrack) return;
    _remote.value = track;
    if (!_remoteReadySent) {
      _remoteReadySent = true;
      _events.add(const RemoteVideoReady());
    }
  }

  void _refreshLocalTrack(lk.Room room) {
    final participant = room.localParticipant;
    if (participant == null) return;
    for (final pub in participant.videoTrackPublications) {
      final t = pub.track;
      if (t is lk.VideoTrack) {
        _local.value = t;
        return;
      }
    }
  }

  @override
  Future<void> leave() async {
    _epoch++;
    final room = _room;
    final listener = _listener;
    _room = null;
    _listener = null;
    _remote.value = null;
    _local.value = null;
    _remoteReadySent = false;
    try {
      await listener?.dispose();
      await room?.disconnect();
      await room?.dispose();
    } on Object catch (e) {
      debugPrint('LiveKit leave ignored error: $e');
    }
  }

  @override
  Widget remoteView() {
    return ValueListenableBuilder<lk.VideoTrack?>(
      valueListenable: _remote,
      builder: (context, track, _) {
        if (track == null) return const ColoredBox(color: AppColors.surface);
        return lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.cover);
      },
    );
  }

  @override
  Widget localView() {
    return ValueListenableBuilder<lk.VideoTrack?>(
      valueListenable: _local,
      builder: (context, track, _) {
        if (track == null) return const ColoredBox(color: AppColors.surface);
        return lk.VideoTrackRenderer(
          track,
          fit: lk.VideoViewFit.cover,
          mirrorMode: lk.VideoViewMirrorMode.mirror,
        );
      },
    );
  }

  @override
  Future<void> setMicEnabled(bool on) async {
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(on);
    } on Object catch (e) {
      debugPrint('setMicEnabled failed: $e');
    }
  }

  @override
  Future<void> setCameraEnabled(bool on) async {
    try {
      await _room?.localParticipant?.setCameraEnabled(on);
      final room = _room;
      if (on && room != null) _refreshLocalTrack(room);
    } on Object catch (e) {
      debugPrint('setCameraEnabled failed: $e');
    }
  }

  @override
  Future<void> switchCamera() async {
    final track = _local.value;
    if (track is! lk.LocalVideoTrack) return;
    try {
      _frontCamera = !_frontCamera;
      await track.setCameraPosition(
        _frontCamera ? lk.CameraPosition.front : lk.CameraPosition.back,
      );
    } on Object catch (e) {
      _frontCamera = !_frontCamera;
      debugPrint('switchCamera failed: $e');
    }
  }

  @override
  Future<void> dispose() async {
    await leave();
    await _events.close();
    _remote.dispose();
    _local.dispose();
  }
}
