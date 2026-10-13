import '../models/api_error.dart';
import '../models/match_found.dart';
import '../services/api_client.dart';
import 'swipe_controller.dart';

/// 6 giá trị `reason` của API.md §1.5 (ánh xạ 1-1 với `reason*` trong ARB).
const List<String> kReportReasons = <String>[
  'nudity',
  'harassment',
  'underage',
  'spam',
  'violence',
  'other',
];

enum ReportOutcome {
  /// Báo cáo (và chặn nếu chọn) đều thành công.
  done,

  /// Báo cáo đã gửi nhưng chặn thất bại → UI hiện `errorGeneric`; app đã `next()`.
  doneBlockFailed,
}

/// Báo cáo / chặn – DESIGN.md S4, T-012.
class SafetyController {
  SafetyController({required ApiClient api, required SwipeActions swipe})
      : _api = api,
        _swipe = swipe;

  final ApiClient _api;
  final SwipeActions _swipe;

  /// `RATE_LIMITED` và mọi [ApiException] của bước báo cáo được ném lại cho UI.
  Future<ReportOutcome> report({
    required Peer peer,
    required String reason,
    String? note,
    required bool alsoBlock,
    String? roomName,
  }) async {
    assert(kReportReasons.contains(reason), 'Unknown report reason: $reason');
    await _api.report(userId: peer.id, reason: reason, roomName: roomName, note: note);

    if (!alsoBlock) {
      await _swipe.next();
      return ReportOutcome.done;
    }
    try {
      // Server tự kết thúc cuộc gọi → app nhận `call.ended reason=blocked` và
      // tự `queue.join` (T-011), nên KHÔNG gọi next() ở nhánh thành công.
      await _api.block(peer.id);
      return ReportOutcome.done;
    } on ApiException {
      await _swipe.next();
      return ReportOutcome.doneBlockFailed;
    }
  }

  /// Chỉ chặn; server kết thúc cuộc gọi nên không gọi `next()`.
  Future<void> block(Peer peer) => _api.block(peer.id);
}
