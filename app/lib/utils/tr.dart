import 'package:flutter/widgets.dart';

/// Chọn chuỗi theo ngôn ngữ hiện tại (vi/en) cho các màn hình mới chưa đưa vào tệp .arb.
String tr(BuildContext context, String vi, String en) =>
    Localizations.localeOf(context).languageCode == 'vi' ? vi : en;
