import 'package:cham/widgets/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BrandMark vẽ được ở nhiều kích thước và có nhãn truy cập', (tester) async {
    for (final size in <double>[24, 76, 200]) {
      await tester.pumpWidget(MaterialApp(home: Center(child: BrandMark(size: size))));
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Chạm'), findsOneWidget);
    }
  });
}
