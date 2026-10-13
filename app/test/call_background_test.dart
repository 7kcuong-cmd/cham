import 'package:cham/state/call_background.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('chọn ảnh nền được lưu và nạp lại', () async {
    SharedPreferences.setMockInitialValues({});
    final s = CallBackgroundSettings.instance;
    await s.select('bg1');
    expect(s.selectedId, 'bg1');
    await s.select('');
    SharedPreferences.setMockInitialValues({'call_background_id': 'bg2'});
    await s.load();
    expect(s.selectedId, 'bg2');
  });
}
