import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Không cần SDK ngoài `flutter test`: đọc thẳng tệp ARB và mã nguồn (cwd = thư mục app/).
Map<String, dynamic> _readArb(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Set<String> _keys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

Set<String> _placeholders(String message) =>
    RegExp(r'\{(\w+)').allMatches(message).map((m) => m.group(1)!).toSet();

void main() {
  final vi = _readArb('lib/l10n/app_vi.arb');
  final en = _readArb('lib/l10n/app_en.arb');

  test('vi và en có đúng cùng tập khóa', () {
    expect(_keys(en).difference(_keys(vi)), isEmpty, reason: 'khóa có ở en nhưng thiếu ở vi');
    expect(_keys(vi).difference(_keys(en)), isEmpty, reason: 'khóa có ở vi nhưng thiếu ở en');
  });

  test('không chuỗi nào rỗng', () {
    for (final arb in <Map<String, dynamic>>[vi, en]) {
      for (final k in _keys(arb)) {
        expect((arb[k] as String).trim(), isNotEmpty, reason: k);
      }
    }
  });

  test('mỗi khóa dùng cùng tập placeholder ở vi và en', () {
    for (final k in _keys(vi).intersection(_keys(en))) {
      expect(_placeholders(en[k] as String), _placeholders(vi[k] as String), reason: k);
    }
  });

  test('khóa có placeholder phải khai báo @khóa.placeholders ở tệp mẫu (vi)', () {
    for (final k in _keys(vi)) {
      final used = _placeholders(vi[k] as String);
      if (used.isEmpty) continue;
      final meta = vi['@$k'];
      expect(meta, isA<Map<String, dynamic>>(), reason: '$k thiếu @$k');
      final declared = ((meta as Map<String, dynamic>)['placeholders'] as Map?)?.keys.toSet();
      expect(declared, isNotNull, reason: '$k thiếu placeholders');
      expect(declared!.cast<String>().containsAll(used), isTrue, reason: k);
    }
  });

  test('mọi khóa dịch dùng trong lib/ đều có trong ARB', () {
    final used = <String, String>{}; // khóa -> tệp đầu tiên dùng
    final re = RegExp(r'(?:l10n|AppLocalizations\.of\(context\))\.([a-zA-Z][a-zA-Z0-9_]*)');
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      // Tệp sinh bởi gen-l10n (nếu có) không phải nơi "dùng".
      if (f.path.contains('${Platform.pathSeparator}l10n${Platform.pathSeparator}')) continue;
      final text = f.readAsStringSync();
      for (final m in re.allMatches(text)) {
        used.putIfAbsent(m.group(1)!, () => f.path);
      }
    }
    // Thành viên có sẵn của lớp sinh, không phải khóa ARB.
    const generatedMembers = <String>{'localeName', 'delegate', 'localizationsDelegates', 'supportedLocales'};
    final missing = <String>[
      for (final e in used.entries)
        if (!generatedMembers.contains(e.key) && !_keys(vi).contains(e.key)) '${e.key} (${e.value})',
    ];
    expect(missing, isEmpty);
  });
}
