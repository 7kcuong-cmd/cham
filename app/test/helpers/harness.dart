import 'package:cham/l10n/app_localizations.dart';
import 'package:cham/services/call_service.dart';
import 'package:cham/services/push_service.dart';
import 'package:cham/state/call_extras_controller.dart';
import 'package:cham/state/contacts_controller.dart';
import 'package:cham/state/game_controller.dart';
import 'package:cham/state/games_list_controller.dart';
import 'package:cham/state/invite_controller.dart';
import 'package:cham/state/safety_controller.dart';
import 'package:cham/state/session_controller.dart';
import 'package:cham/state/swipe_controller.dart';
import 'package:cham/state/wallet_controller.dart';
import 'package:cham/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart' show WidgetTester, addTearDown;
import 'package:provider/provider.dart';

/// Bọc [home] trong MaterialApp có theme, l10n và các Provider cần cho test widget.
Widget harness({
  required Widget home,
  SessionController? session,
  SwipeController? swipe,
  SafetyController? safety,
  CallService? call,
  ContactsController? contacts,
  InviteController? invites,
  CallExtrasController? extras,
  WalletController? wallet,
  GameController? game,
  GamesListController? gamesList,
  PushService? push,
  Locale locale = const Locale('vi'),
  double textScale = 1.0,
}) {
  final app = MaterialApp(
      theme: buildTheme(),
      themeMode: ThemeMode.dark,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
  );
  // Bọc lần lượt từng provider quanh app (không dùng MultiProvider: nó cấm danh sách rỗng).
  Widget result = app;
  if (push != null) result = Provider<PushService>.value(value: push, child: result);
  if (gamesList != null) result = ChangeNotifierProvider<GamesListController>.value(value: gamesList, child: result);
  if (game != null) result = ChangeNotifierProvider<GameController>.value(value: game, child: result);
  if (wallet != null) result = ChangeNotifierProvider<WalletController>.value(value: wallet, child: result);
  if (extras != null) result = ChangeNotifierProvider<CallExtrasController>.value(value: extras, child: result);
  if (invites != null) result = ChangeNotifierProvider<InviteController>.value(value: invites, child: result);
  if (contacts != null) result = ChangeNotifierProvider<ContactsController>.value(value: contacts, child: result);
  if (call != null) result = Provider<CallService>.value(value: call, child: result);
  if (safety != null) result = Provider<SafetyController>.value(value: safety, child: result);
  if (swipe != null) result = ChangeNotifierProvider<SwipeController>.value(value: swipe, child: result);
  if (session != null) result = ChangeNotifierProvider<SessionController>.value(value: session, child: result);
  return result;
}

/// Màn hình đủ cao để các sheet/danh sách không bị cuộn trong test.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Màn hình hẹp 320 x 640 dp (kiểm tra không tràn ở bản en, chữ to 1,3).
void useNarrowSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}
