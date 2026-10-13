import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/avatar.dart';
import '../services/api_client.dart';

/// Bộ nhớ đệm ảnh đại diện theo userId (tải siêu dữ liệu một lần, làm mới khi gọi [refresh]).
class AvatarCache extends ChangeNotifier {
  AvatarCache({required ApiClient api}) : _api = api;

  final ApiClient _api;
  final Map<String, Avatar?> _map = <String, Avatar?>{};
  final Set<String> _loading = <String>{};

  /// Đã tải xong chưa (kể cả khi người đó chưa đặt ảnh).
  bool known(String userId) => _map.containsKey(userId);

  Avatar? of(String userId) {
    if (!_map.containsKey(userId) && _loading.add(userId)) {
      unawaited(_load(userId));
    }
    return _map[userId];
  }

  Future<void> _load(String userId) async {
    try {
      _map[userId] = await _api.getAvatar(userId);
    } on Object {
      // lỗi mạng: thử lại lần sau
      _loading.remove(userId);
      return;
    }
    _loading.remove(userId);
    notifyListeners();
  }

  Future<void> refresh(String userId) async {
    _map.remove(userId);
    _loading.remove(userId);
    notifyListeners();
    await _load(userId);
  }

  void set(String userId, Avatar? a) {
    _map[userId] = a;
    notifyListeners();
  }
}
