import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/api_error.dart';
import '../models/discovery.dart';
import '../services/api_client.dart';
import '../state/contacts_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// Thêm liên hệ: tìm (email / số điện thoại / tên), mã QR của mình, quét QR của người khác.
class AddContactScreen extends StatelessWidget {
  const AddContactScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr(context, 'Thêm liên hệ', 'Add contact')),
          bottom: TabBar(tabs: [
            Tab(icon: const Icon(Icons.search_rounded), text: tr(context, 'Tìm', 'Search')),
            Tab(icon: const Icon(Icons.qr_code_2_rounded), text: tr(context, 'Mã của tôi', 'My code')),
            Tab(icon: const Icon(Icons.qr_code_scanner_rounded), text: tr(context, 'Quét mã', 'Scan')),
          ]),
        ),
        body: const TabBarView(
          physics: NeverScrollableScrollPhysics(), // tab Quét dùng camera, tránh vuốt nhầm
          children: [_SearchTab(), _MyCodeTab(), _ScanTab()],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Tìm kiếm

class _SearchTab extends StatefulWidget {
  const _SearchTab();

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final _ctl = TextEditingController();
  List<UserHit> _hits = const <UserHit>[];
  bool _busy = false;
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctl.text.trim();
    if (q.length < 2 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hits = await context.read<ApiClient>().searchUsers(q);
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searched = true;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _invite(UserHit h) async {
    final r = await context.read<ContactsController>().sendRequest(h.id);
    if (!mounted) return;
    if (r.startsWith('error:')) {
      _snack(errorText(AppLocalizations.of(context), r.substring(6)));
      return;
    }
    setState(() {
      _hits = [for (final x in _hits) x.id == h.id ? x.withRelation(r == 'sent' ? 'requested' : 'contact') : x];
    });
    _snack(r == 'sent'
        ? tr(context, 'Đã gửi lời mời tới ${h.displayName}.', 'Request sent to ${h.displayName}.')
        : tr(context, 'Bạn và ${h.displayName} đã là bạn.', 'You and ${h.displayName} are now friends.'));
  }

  void _snack(String t) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(t)));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctl,
            textInputAction: TextInputAction.search,
            keyboardType: TextInputType.emailAddress,
            onSubmitted: (_) => unawaited(_search()),
            decoration: InputDecoration(
              hintText: tr(context, 'Email, số điện thoại hoặc tên', 'Email, phone number or name'),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward_rounded),
                tooltip: tr(context, 'Tìm', 'Search'),
                onPressed: _busy ? null : () => unawaited(_search()),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            tr(
              context,
              'Email và số điện thoại phải nhập đúng đầy đủ. Tên chỉ tìm được người đã bật "Cho phép tìm theo tên" trong Cài đặt.',
              'Email and phone must match exactly. Names only find people who turned on "Find me by name" in Settings.',
            ),
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpace.md),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(errorText(AppLocalizations.of(context), _error!), style: const TextStyle(color: AppColors.danger)),
          if (_searched && _hits.isEmpty && !_busy)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.lg),
              child: Text(
                tr(context, 'Không tìm thấy ai. Người đó có thể đã tắt chế độ cho phép tìm.',
                    'Nobody found. They may have turned discovery off.'),
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                for (final h in _hits)
                  ListTile(
                    leading: CircleAvatar(child: Text(h.displayName.isEmpty ? '?' : h.displayName.characters.first.toUpperCase())),
                    title: Text(h.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: switch (h.relation) {
                      'contact' => Text(tr(context, 'Đã là bạn', 'Friends')),
                      'requested' => Text(tr(context, 'Đã mời', 'Requested')),
                      'incoming' => FilledButton(
                          onPressed: () => unawaited(_invite(h)),
                          child: Text(tr(context, 'Chấp nhận', 'Accept')),
                        ),
                      _ => FilledButton(
                          onPressed: () => unawaited(_invite(h)),
                          child: Text(tr(context, 'Kết bạn', 'Add')),
                        ),
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ Mã của tôi

class _MyCodeTab extends StatefulWidget {
  const _MyCodeTab();

  @override
  State<_MyCodeTab> createState() => _MyCodeTabState();
}

class _MyCodeTabState extends State<_MyCodeTab> {
  String? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await context.read<ApiClient>().getContactCode();
      if (mounted) setState(() => _code = r.link);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(errorText(AppLocalizations.of(context), _error!)));
    final code = _code;
    if (code == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppRadius.card)),
              child: QrImageView(data: code, size: 240, backgroundColor: Colors.white),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(
              tr(context, 'Đưa mã này cho bạn bè quét để thêm nhau ngay.', 'Let a friend scan this code to add each other instantly.'),
              textAlign: TextAlign.center,
              style: AppText.label,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              tr(context, 'Ai quét được mã này sẽ thành bạn của bạn. Đừng đăng công khai.',
                  'Anyone who scans this becomes your contact. Do not post it publicly.'),
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Quét mã

class _ScanTab extends StatefulWidget {
  const _ScanTab();

  @override
  State<_ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<_ScanTab> {
  bool _handling = false;
  String? _message;

  Future<void> _onCode(String raw) async {
    if (_handling) return;
    final code = parseContactCodeFromScan(raw);
    if (code == null) return; // QR khác (ví dụ mã liên kết web): bỏ qua
    _handling = true;
    final err = await context.read<ContactsController>().addByCode(code);
    if (!mounted) return;
    if (err == null) {
      final m = ScaffoldMessenger.of(context);
      m.showSnackBar(SnackBar(content: Text(tr(context, 'Đã thêm vào danh bạ.', 'Added to your contacts.'))));
      Navigator.of(context).pop();
    } else {
      setState(() => _message = errorText(AppLocalizations.of(context), err));
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _message = null);
      _handling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          onDetect: (capture) {
            for (final b in capture.barcodes) {
              final v = b.rawValue;
              if (v != null) {
                unawaited(_onCode(v));
                break;
              }
            }
          },
        ),
        Positioned(
          left: AppSpace.lg,
          right: AppSpace.lg,
          bottom: AppSpace.xl,
          child: Text(
            _message ?? tr(context, 'Hướng camera vào mã QR của bạn bè.', "Point the camera at your friend's QR code."),
            textAlign: TextAlign.center,
            style: AppText.label.copyWith(color: Colors.white, shadows: const [Shadow(blurRadius: 6)]),
          ),
        ),
      ],
    );
  }
}
