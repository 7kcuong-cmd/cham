import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/env.dart';
import '../l10n/app_localizations.dart';
import '../services/media_pick_guard.dart';
import '../services/presence_reporter.dart';
import '../state/chat_controller.dart';
import '../utils/tr.dart';
import '../state/contacts_controller.dart';
import '../state/swipe_controller.dart';
import '../widgets/call_overlays.dart';
import 'contacts_screen.dart';
import '../games/game_library_screen.dart';
import 'settings_screen.dart';
import 'swipe_screen.dart';

enum _Tab { swipe, contacts, games, settings }

/// Khung các tab (DESIGN.md §3): Lướt, Danh bạ, Trò chơi, Cài đặt (bản GĐ1: chỉ Lướt và Cài đặt).
/// Báo cho [SwipeController] khi vào/rời tab Lướt và khi app xuống/lên nền (API.md §2.7 mục 1, 5),
/// báo `presence.update` cho server (API-GD2-4 §3.2) và phủ màn hình cuộc gọi đến/đi.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.showSocial});

  /// Hiện các tab và lớp tương tác GĐ2–4. `null` = theo `Env.featureSocial`.
  final bool? showSocial;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  static const int _swipeTab = 0;

  int _index = _swipeTab;
  late final SwipeController _swipe;
  PresenceReporter? _presence;
  StreamSubscription<ContactCallEnd>? _endSub;
  late final List<_Tab> _tabs;

  bool get _social => widget.showSocial ?? Env.featureSocial;

  @override
  void initState() {
    super.initState();
    _swipe = context.read<SwipeController>();
    _tabs = _social
        ? const [_Tab.swipe, _Tab.contacts, _Tab.games, _Tab.settings]
        : const [_Tab.swipe, _Tab.settings];
    if (_social) {
      _presence = context.read<PresenceReporter>();
      _swipe.addListener(_onSwipeChanged);
      _endSub = _swipe.contactCallEnds.listen(_onContactCallEnd);
    }
    WidgetsBinding.instance.addObserver(this);
    // Sau khung hình đầu để không notifyListeners trong lúc dựng.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _index == _swipeTab) unawaited(_swipe.activate());
    });
  }

  @override
  void dispose() {
    _bgGrace?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_social) _swipe.removeListener(_onSwipeChanged);
    _endSub?.cancel();
    // dispose chạy khi cây đang khóa: hoãn để notifyListeners không đụng cây.
    scheduleMicrotask(() => unawaited(_swipe.deactivate()));
    super.dispose();
  }

  /// Cuộc gọi lại bạn bè (hoặc nghe máy) vào được ở tab khác: chuyển sang tab Lướt để thấy video.
  void _onSwipeChanged() {
    if (!mounted) return;
    final contact = _swipe.isContactCall && _swipe.inCallOrConnecting;
    if (contact != _contactCallActive) {
      setState(() => _contactCallActive = contact); // cuộc gọi danh bạ: lớp phủ riêng, không đổi tab
    } else if (!contact && _swipe.inCallOrConnecting && _index != _swipeTab) {
      setState(() => _index = _swipeTab); // cuộc gọi lướt thật sự (hiếm): vẫn về tab Lướt
    }
  }

  /// Cuộc gọi danh bạ đang hiện toàn màn hình, tách khỏi tab Lướt.
  bool _contactCallActive = false;
  final GlobalKey _swipeKey = GlobalKey();

  /// Cuộc gọi danh bạ xong: về tab Danh bạ; nếu bạn cúp máy thì báo "đã cúp máy".
  void _onContactCallEnd(ContactCallEnd e) {
    if (!mounted) return;
    final i = _tabs.indexOf(_Tab.contacts);
    // Chỉ kéo về Danh bạ nếu người dùng đang ở tab Lướt (màn hình cuộc gọi). Đang ở tab khác thì giữ nguyên.
    // Cuộc gọi danh bạ kết thúc (mình/bạn cúp, mất mạng...) KHÔNG BAO GIỜ tự sang Lướt.
    _forcedSwipe = false;
    if (_contactCallActive) setState(() => _contactCallActive = false);
    if (i >= 0 && _index == _swipeTab) {
      setState(() => _index = i);
      unawaited(context.read<ContactsController>().load());
    } else if (i >= 0 && _index == i) {
      unawaited(context.read<ContactsController>().load());
    }
    if (e.network) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text(tr(context, 'Cuộc gọi bị ngắt do mất kết nối.', 'The call ended because the connection was lost.'))));
    }
    if (e.byPeer) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).contactHungUp(e.peer.displayName))),
      );
    }
  }

  /// Đang gọi mà app ra nền (đổi app, kéo thanh thông báo, bộ chọn tệp...): giữ cuộc gọi thêm chừng này rồi mới ngắt.
  static const backgroundCallGrace = Duration(seconds: 20);
  Timer? _bgGrace;

  /// Đang ở tab Lướt do một cuộc gọi danh bạ tự chuyển sang (không phải người dùng chọn). Khi đó quay lại app KHÔNG tự
  /// vào hàng chờ lướt: cuộc gọi danh bạ và lướt ngẫu nhiên tách biệt.
  bool _forcedSwipe = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _bgGrace?.cancel();
        _bgGrace = null;
        _presence?.setForeground(true);
        if (_index == _swipeTab && !_forcedSwipe) unawaited(_swipe.activate());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Bộ chọn tệp/ảnh của hệ thống làm app sang nền trong vài giây: tuyệt đối không cắt cuộc gọi.
        if (MediaPickGuard.active) break;
        _presence?.setForeground(false);
        if (_swipe.inCallOrConnecting) {
          _bgGrace?.cancel();
          _bgGrace = Timer(backgroundCallGrace, () {
            _bgGrace = null;
            final life = WidgetsBinding.instance.lifecycleState;
            if (life == null || life == AppLifecycleState.resumed) return;
            unawaited(_swipe.deactivate());
          });
        } else {
          unawaited(_swipe.deactivate());
        }
      case AppLifecycleState.inactive:
        // inactive xảy ra cả khi hiện hộp thoại xin quyền → không rời hàng chờ.
        break;
    }
  }

  void _onTab(int i) {
    if (i == _index) return;
    _forcedSwipe = false; // người dùng tự chọn tab
    setState(() => _index = i);
    final tab = _tabs[i];
    if (tab == _Tab.swipe) {
      unawaited(_swipe.activate());
    } else {
      unawaited(_swipe.deactivate());
    }
    // Mỗi lần vào tab: tải lại (trạng thái online của bạn bè, lịch sử ván).
    if (tab == _Tab.contacts) {
      final cc = context.read<ContactsController>();
      unawaited(cc.load());
      unawaited(cc.loadRequests());
    }
  }

  Widget _screenFor(_Tab tab) {
    switch (tab) {
      case _Tab.swipe:
        return _contactCallActive
            ? const SizedBox.shrink()
            : SwipeScreen(key: _swipeKey, showSocial: _social);
      case _Tab.contacts:
        return const ContactsScreen();
      case _Tab.games:
        return const GameLibraryScreen();
      case _Tab.settings:
        return SettingsScreen(showSocial: _social);
    }
  }

  /// Tổng tin chưa đọc (0 nếu không có ChatController, ví dụ trong test dựng riêng).
  int _totalUnread(BuildContext context) {
    try {
      return context.watch<ChatController>().totalUnread;
    } on Object {
      return 0;
    }
  }

  NavigationDestination _destinationFor(AppLocalizations l10n, _Tab tab) {
    switch (tab) {
      case _Tab.swipe:
        return NavigationDestination(icon: const Icon(Icons.explore_rounded), label: l10n.tabSwipe);
      case _Tab.contacts:
        return NavigationDestination(
          icon: Badge(
            isLabelVisible: _totalUnread(context) > 0,
            label: Text('${_totalUnread(context)}'),
            child: const Icon(Icons.people_rounded),
          ),
          label: l10n.tabContacts,
        );
      case _Tab.games:
        return NavigationDestination(
          icon: const Icon(Icons.sports_esports_rounded),
          label: l10n.tabGames,
        );
      case _Tab.settings:
        return NavigationDestination(
          icon: const Icon(Icons.settings_rounded),
          label: l10n.tabSettings,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scaffold = Scaffold(
      // Bàn phím (ô bình luận) không làm video co lại.
      resizeToAvoidBottomInset: false,
      body: IndexedStack(
        index: _index,
        children: [for (final tab in _tabs) _screenFor(tab)],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onTab,
        destinations: [for (final tab in _tabs) _destinationFor(l10n, tab)],
      ),
    );
    if (!_social) return scaffold;
    return CallOverlays(
      child: Stack(children: [
        Positioned.fill(child: scaffold),
        if (_contactCallActive)
          Positioned.fill(
            child: PopScope(
              canPop: false, // Back không thoát cuộc gọi; cúp bằng nút đỏ
              child: Material(
                color: Colors.black,
                child: SwipeScreen(key: _swipeKey, showSocial: _social),
              ),
            ),
          ),
      ]),
    );
  }
}
