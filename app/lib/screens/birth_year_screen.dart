import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../state/session_controller.dart';
import '../theme/tokens.dart';
import '../utils/age.dart';

/// Ký hiệu "chưa chọn" ở giữa bánh xe (không phải chuỗi giao diện dịch được).
const String _kNoSelection = '—';

/// S2 – Hỏi năm sinh (DESIGN.md S2). Ban đầu KHÔNG chọn sẵn năm nào.
class BirthYearScreen extends StatefulWidget {
  const BirthYearScreen({super.key, this.nowYear});

  /// Năm hiện tại (test có thể ép). Mặc định theo giờ máy.
  final int? nowYear;

  @override
  State<BirthYearScreen> createState() => _BirthYearScreenState();
}

class _BirthYearScreenState extends State<BirthYearScreen> {
  static const double _itemExtent = 48;

  late final int _nowYear = widget.nowYear ?? DateTime.now().year;
  late final List<int> _years = birthYearChoices(_nowYear);
  final FixedExtentScrollController _wheel = FixedExtentScrollController();
  StreamSubscription<String>? _errorSub;

  /// Chỉ số đang ở giữa: 0 = ô trống "—", i >= 1 ứng với `_years[i - 1]`.
  int _centerIndex = 0;

  int? get _selectedYear => _centerIndex == 0 ? null : _years[_centerIndex - 1];

  @override
  void initState() {
    super.initState();
    _errorSub = context.read<SessionController>().errors.listen((code) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(errorText(l10n, code))));
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _wheel.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final year = _selectedYear;
    if (year == null) return;
    final l10n = AppLocalizations.of(context);
    final session = context.read<SessionController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.birthYearConfirmTitle(year.toString())),
        content: Text(l10n.birthYearConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await session.submitBirthYear(year);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.watch<SessionController>();
    final busy = session.busy;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: busy ? null : session.signOut,
                  child: Text(l10n.signOut),
                ),
              ),
              Text(l10n.birthYearTitle, style: AppText.title),
              const SizedBox(height: AppSpace.sm),
              Text(
                l10n.birthYearBody,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
              Expanded(child: _buildWheel()),
              FilledButton(
                onPressed: (_selectedYear == null || busy) ? null : _continue,
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.onPrimary,
                        ),
                      )
                    : Text(l10n.continueAction),
              ),
              const SizedBox(height: AppSpace.xl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWheel() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          height: _itemExtent,
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
        ),
        ListWheelScrollView.useDelegate(
          controller: _wheel,
          itemExtent: _itemExtent,
          diameterRatio: 2.2,
          physics: const FixedExtentScrollPhysics(),
          onSelectedItemChanged: (i) => setState(() => _centerIndex = i),
          childDelegate: ListWheelChildBuilderDelegate(
            childCount: _years.length + 1,
            builder: (context, i) {
              final isCenter = i == _centerIndex;
              final label = i == 0 ? _kNoSelection : _years[i - 1].toString();
              return Center(
                child: Text(
                  label,
                  style: isCenter
                      ? AppText.title
                      : AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
