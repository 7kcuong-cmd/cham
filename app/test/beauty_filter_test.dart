import 'package:cham/widgets/beauty_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(int level, void Function() onBuild) => MaterialApp(
        home: SizedBox(
          width: 100,
          height: 100,
          child: BeautyFilter(
            level: level,
            builder: (_) {
              onBuild();
              return const ColoredBox(color: Colors.pink);
            },
          ),
        ),
      );

  testWidgets('mức 0: không lọc, chỉ dựng hình gốc một lần', (tester) async {
    var n = 0;
    await tester.pumpWidget(host(0, () => n++));
    expect(n, 1);
    expect(find.byType(ColorFiltered), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('mức > 0: hình gốc đã chỉnh tông + lớp mờ phía trên', (tester) async {
    var n = 0;
    await tester.pumpWidget(host(60, () => n++));
    expect(n, 2);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mức ngoài khoảng bị chặn, không lỗi', (tester) async {
    await tester.pumpWidget(host(500, () {}));
    expect(tester.takeException(), isNull);
  });
}
