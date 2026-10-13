import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../config/env.dart';
import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../state/session_controller.dart';
import '../state/wallet_controller.dart';
import '../theme/tokens.dart';
import '../utils/links.dart';
import '../utils/tr.dart';
import '../security/shield_controller.dart';
import '../services/recording_privacy.dart';
import '../state/privacy_settings.dart';
import '../widgets/call_background.dart';
import 'app_lock_settings_screen.dart';
import 'avatar_screen.dart';
import 'link_scan_screen.dart';
import 'discovery_settings_screen.dart';
import 'phone_verify_screen.dart';
import 'blocked_users_screen.dart';
import 'wallet_screen.dart';

/// Kiểm tra tên hiển thị: sau `trim()` dài 1–30 ký tự, không có ký tự điều khiển
/// (API.md §1.3). Độ dài tính theo đơn vị UTF-16 như `String.length` của JS ở server.
bool isValidDisplayName(String raw) {
  final name = raw.trim();
  if (name.isEmpty || name.length > 30) return false;
  return !RegExp(r'[\u0000-\u001F\u007F]').hasMatch(name);
}

/// Cài đặt tối thiểu GĐ1 (DESIGN.md "Cài đặt").
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.versionLoader, this.showSocial});

  /// Hiện hàng "Điểm của tôi" và "Người đã chặn" (GĐ2–3). `null` = theo `Env.featureSocial`.
  final bool? showSocial;

  /// Tiêm cho test; mặc định đọc từ `package_info_plus`.
  final Future<String> Function()? versionLoader;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final loader = widget.versionLoader ?? _platformVersion;
      final v = await loader();
      if (mounted) setState(() => _version = v);
    } on Object {
      // Không có phiên bản thì không hiện dòng đó.
    }
  }

  static Future<String> _platformVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  Future<void> _editName(SessionController session) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: session.user?.displayName ?? ''),
    );
    if (result == null) return;
    final ok = await session.updateDisplayName(result);
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(errorText(l10n, session.errorCode ?? 'INTERNAL'))),
      );
    }
  }

  Future<void> _pickLanguage(SessionController session) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final current = session.user?.language;
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.language),
        children: [
          _LanguageOption(
            label: l10n.languageVi,
            selected: current == 'vi',
            onTap: () => Navigator.of(dialogContext).pop('vi'),
          ),
          _LanguageOption(
            label: l10n.languageEn,
            selected: current == 'en',
            onTap: () => Navigator.of(dialogContext).pop('en'),
          ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    final ok = await session.updateLanguage(picked);
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(errorText(l10n, session.errorCode ?? 'INTERNAL'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.watch<SessionController>();
    final user = session.user;
    final languageName = user?.language == 'en' ? l10n.languageEn : l10n.languageVi;
    final social = widget.showSocial ?? Env.featureSocial;
    final balance = social ? context.watch<WalletController>().balance : null;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(top: AppSpace.lg),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
            child: Text(l10n.tabSettings, style: AppText.title),
          ),
          _SettingsRow(
            label: l10n.displayName,
            value: user?.displayName,
            onTap: () => _editName(session),
          ),
          _SettingsRow(
            label: l10n.language,
            value: languageName,
            onTap: () => _pickLanguage(session),
          ),
          if (social)
            _SettingsRow(
              label: tr(context, 'Ảnh đại diện', 'Profile picture'),
              trailingIcon: Icons.chevron_right_rounded,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AvatarScreen()),
              ),
            ),
          _SettingsRow(
            label: tr(context, 'Ảnh nền cuộc gọi', 'Call background'),
            trailingIcon: Icons.chevron_right_rounded,
            onTap: () => showCallBackgroundPicker(context),
          ),
          ListenableBuilder(
            listenable: PrivacySettings.instance,
            builder: (context, _) => SwitchListTile(
              value: PrivacySettings.instance.relayOnly,
              onChanged: (v) => PrivacySettings.instance.set(v),
              title: Text(tr(context, 'Chế độ riêng tư (ẩn IP)', 'Privacy mode (hide IP)')),
              subtitle: Text(tr(
                context,
                'Cuộc gọi đi qua máy chủ chuyển tiếp nên người kia không thấy IP của bạn. Có thể chậm hơn; nếu máy chủ chưa hỗ trợ thì không gọi được.',
                'Calls go through a relay so the other person cannot see your IP. May be slower; if the server has no relay, calls will not connect.',
              )),
            ),
          ),
          ListenableBuilder(
            listenable: ShieldController.instance,
            builder: (context, _) => SwitchListTile(
              value: ShieldController.instance.enabled,
              onChanged: (v) => ShieldController.instance.setEnabled(v),
              title: Text(tr(context, 'Bảo vệ chống dò IP', 'Protect against IP probing')),
              subtitle: Text(tr(
                context,
                'Lọc địa chỉ mạng khi gọi, tự ngắt và chặn người có dấu hiệu dò IP của bạn. Khuyên dùng bật.',
                'Filters network addresses during calls and automatically ends the call and blocks people who look like they are probing your IP. Recommended.',
              )),
            ),
          ),
          if (social)
            _SettingsRow(
              label: tr(context, 'Liên kết với web', 'Link with web'),
              trailingIcon: Icons.chevron_right_rounded,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LinkScanScreen()),
              ),
            ),
          ListenableBuilder(
            listenable: RecordingPrivacy.instance,
            builder: (context, _) => SwitchListTile(
              secondary: const Icon(Icons.blur_on_rounded),
              value: RecordingPrivacy.instance.blurPeerFace,
              onChanged: (v) => RecordingPrivacy.instance.set(v),
              title: Text(tr(context, 'Làm mờ mặt người đối diện khi ghi hình', 'Pixelate the other person\'s face when recording')),
              subtitle: Text(tr(
                context,
                'Khuôn mặt người kia được che bằng ô pixel trong clip bạn ghi. Nếu chưa nhận ra mặt, cả khung hình sẽ được làm mờ. Khuyên dùng bật.',
                'The other person\'s face is covered with pixel blocks in your clip. If no face is found, the whole frame is blurred. Recommended.',
              )),
            ),
          ),
          if (social)
            _SettingsRow(
              label: tr(context, 'Cho phép người khác tìm bạn', 'Let others find you'),
              trailingIcon: Icons.chevron_right_rounded,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DiscoverySettingsScreen()),
              ),
            ),
          if (social)
            _SettingsRow(
              label: tr(context, 'Xác minh số điện thoại', 'Verify phone number'),
              trailingIcon: Icons.chevron_right_rounded,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PhoneVerifyScreen()),
              ),
            ),
          _SettingsRow(
            label: tr(context, 'Khóa ứng dụng', 'App lock'),
            trailingIcon: Icons.chevron_right_rounded,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AppLockSettingsScreen()),
            ),
          ),
          if (social)
            _SettingsRow(
              label: l10n.myPoints,
              value: balance == null ? null : l10n.pointsBalance('$balance'),
              trailingIcon: Icons.chevron_right_rounded,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const WalletScreen()),
              ),
            ),
          if (social)
            _SettingsRow(
              label: l10n.blockedUsers,
              trailingIcon: Icons.chevron_right_rounded,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const BlockedUsersScreen()),
              ),
            ),
          if (Env.termsUrl.isNotEmpty)
            _SettingsRow(
              label: l10n.terms,
              trailingIcon: Icons.open_in_new_rounded,
              onTap: () => openExternalUrl(Env.termsUrl),
            ),
          if (Env.privacyUrl.isNotEmpty)
            _SettingsRow(
              label: l10n.privacy,
              trailingIcon: Icons.open_in_new_rounded,
              onTap: () => openExternalUrl(Env.privacyUrl),
            ),
          _SettingsRow(
            label: l10n.signOut,
            color: AppColors.danger,
            onTap: session.signOut,
          ),
          if (_version != null)
            Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Text(
                '${l10n.appVersion(_version!)} · ${Env.buildId}',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.label,
    required this.onTap,
    this.value,
    this.trailingIcon,
    this.color = AppColors.textPrimary,
  });

  final String label;
  final String? value;
  final IconData? trailingIcon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: AppSize.settingsRow,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.outline)),
        ),
        child: Row(
          children: [
            Text(label, style: AppText.body.copyWith(color: color)),
            const Spacer(),
            if (value != null)
              Flexible(
                child: Text(
                  value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              ),
            if (trailingIcon != null)
              Icon(trailingIcon, size: 20, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _LanguageOption extends StatelessWidget {
  const _LanguageOption({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      onPressed: onTap,
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.body)),
          if (selected) const Icon(Icons.check_rounded, color: AppColors.primary),
        ],
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);
  bool _invalid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text;
    if (!isValidDisplayName(text)) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.displayName),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: AppText.body,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        onChanged: (_) {
          if (_invalid) setState(() => _invalid = false);
        },
        decoration: InputDecoration(
          errorText: _invalid ? l10n.displayNameInvalid : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          onPressed: _save,
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
