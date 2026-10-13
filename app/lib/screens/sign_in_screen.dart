import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/env.dart';
import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../services/auth_service.dart';
import '../state/session_controller.dart';
import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';
import '../utils/links.dart';
import '../utils/tr.dart';
import 'email_sign_in_screen.dart';

enum _Pressed { none, google, apple, dev }

/// S1 – Đăng nhập (DESIGN.md S1). `AUTH_MODE=dev` thay hai nút bằng ô nhập uid.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.devMode, this.showApple});

  /// Mặc định `Env.isDev` (test có thể ép).
  final bool? devMode;

  /// Mặc định: chỉ iOS (test có thể ép).
  final bool? showApple;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final TextEditingController _uid = TextEditingController();
  StreamSubscription<String>? _errorSub;
  _Pressed _pressed = _Pressed.none;
  bool _uidInvalid = false;

  bool get _dev => widget.devMode ?? Env.isDev;
  bool get _apple => widget.showApple ?? defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _errorSub = context.read<SessionController>().errors.listen(_showError);
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _uid.dispose();
    super.dispose();
  }

  void _showError(String code) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(errorText(l10n, code))));
  }

  Future<void> _run(_Pressed which, Future<void> Function() action) async {
    setState(() => _pressed = which);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _pressed = _Pressed.none);
    }
  }

  void _submitDev(SessionController session) {
    final uid = _uid.text.trim();
    if (!DevAuthService.isValidUid(uid)) {
      setState(() => _uidInvalid = true);
      return;
    }
    setState(() => _uidInvalid = false);
    unawaited(_run(_Pressed.dev, () => session.signInDev(uid)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.watch<SessionController>();
    final busy = session.busy;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(top: AppSpace.sm),
                          child: _dev
                              ? Text(
                                  l10n.devBadge,
                                  style: AppText.caption.copyWith(color: AppColors.danger),
                                )
                              : const SizedBox(height: AppSpace.lg),
                        ),
                      ),
                      const Spacer(flex: 4),
                      Center(
                        child: Container(
                          width: 132,
                          height: 132,
                          decoration: const BoxDecoration(shape: BoxShape.circle, gradient: AppGradients.glow),
                          alignment: Alignment.center,
                          child: const BrandMark(size: 76),
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Text(
                        l10n.appTitle,
                        textAlign: TextAlign.center,
                        style: AppText.display.copyWith(color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Text(
                        l10n.signInTagline,
                        textAlign: TextAlign.center,
                        style: AppText.body.copyWith(color: AppColors.textSecondary),
                      ),
                      const Spacer(flex: 6),
                      if (_dev) ..._devForm(l10n, session, busy) else ..._socialButtons(l10n, session, busy),
                      const SizedBox(height: AppSpace.lg),
                      Text(
                        l10n.signInLegal,
                        textAlign: TextAlign.center,
                        style: AppText.caption.copyWith(color: AppColors.textSecondary),
                      ),
                      _legalLinks(l10n),
                      const SizedBox(height: AppSpace.xxl),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _socialButtons(AppLocalizations l10n, SessionController session, bool busy) {
    return [
      _AuthButton(
        label: l10n.signInGoogle,
        icon: Icons.g_mobiledata_rounded,
        background: AppColors.textPrimary,
        foreground: AppColors.bg,
        loading: busy && _pressed == _Pressed.google,
        onPressed: busy ? null : () => _run(_Pressed.google, session.signInGoogle),
      ),
      ..._emailButton(session, busy),
      if (_apple) ...[
        const SizedBox(height: AppSpace.md),
        _AuthButton(
          label: l10n.signInApple,
          background: AppColors.appleButton,
          foreground: AppColors.textPrimary,
          border: AppColors.outline,
          loading: busy && _pressed == _Pressed.apple,
          onPressed: busy ? null : () => _run(_Pressed.apple, session.signInApple),
        ),
      ],
    ];
  }

  List<Widget> _emailButton(SessionController session, bool busy) {
    if (session.emailAuth == null) return const <Widget>[];
    return [
      const SizedBox(height: AppSpace.md),
      _AuthButton(
        label: tr(context, 'Đăng nhập bằng email', 'Continue with email'),
        icon: Icons.mail_outline,
        background: AppColors.appleButton,
        foreground: AppColors.textPrimary,
        border: AppColors.outline,
        loading: false,
        onPressed: busy ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const EmailSignInScreen())),
      ),
    ];
  }

  List<Widget> _devForm(AppLocalizations l10n, SessionController session, bool busy) {
    return [
      TextField(
        controller: _uid,
        enabled: !busy,
        autocorrect: false,
        enableSuggestions: false,
        style: AppText.body,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submitDev(session),
        decoration: InputDecoration(
          hintText: l10n.devUidHint,
          errorText: _uidInvalid ? l10n.devUidInvalid : null,
        ),
      ),
      const SizedBox(height: AppSpace.md),
      FilledButton(
        onPressed: busy ? null : () => _submitDev(session),
        child: (busy && _pressed == _Pressed.dev)
            ? const _Spinner(color: AppColors.onPrimary)
            : Text(l10n.devSignIn),
      ),
      ..._emailButton(session, busy),
    ];
  }

  Widget _legalLinks(AppLocalizations l10n) {
    final links = <Widget>[
      if (Env.termsUrl.isNotEmpty) _LegalLink(label: l10n.terms, url: Env.termsUrl),
      if (Env.privacyUrl.isNotEmpty) _LegalLink(label: l10n.privacy, url: Env.privacyUrl),
    ];
    if (links.isEmpty) return const SizedBox(height: AppSpace.sm);
    return Wrap(alignment: WrapAlignment.center, spacing: AppSpace.lg, children: links);
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }
}

class _AuthButton extends StatelessWidget {
  const _AuthButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onPressed,
    required this.loading,
    this.icon,
    this.border,
  });

  final String label;
  final IconData? icon;
  final Color background;
  final Color foreground;
  final Color? border;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final shape = StadiumBorder(
      side: border == null ? BorderSide.none : BorderSide(color: border!),
    );
    return Material(
      color: background,
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onPressed,
        child: SizedBox(
          height: AppSize.buttonHeight,
          child: Center(
            child: loading
                ? _Spinner(color: foreground)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 28, color: foreground),
                        const SizedBox(width: AppSpace.sm),
                      ],
                      Text(label, style: AppText.label.copyWith(color: foreground)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _LegalLink extends StatelessWidget {
  const _LegalLink({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => openExternalUrl(url),
      child: Text(
        label,
        style: AppText.caption.copyWith(decoration: TextDecoration.underline),
      ),
    );
  }
}
