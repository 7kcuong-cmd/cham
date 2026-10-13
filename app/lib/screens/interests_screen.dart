import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/interests.dart';
import '../state/session_controller.dart';
import '../theme/tokens.dart';

/// Chọn nhóm/sở thích khi đăng ký (nghệ thuật, nghề nghiệp, sở thích…). Có thể bỏ qua.
/// Dùng để ưu tiên ghép với người có điểm chung (cùng ngôn ngữ trước, rồi nhiều điểm chung nhất).
class InterestsScreen extends StatefulWidget {
  const InterestsScreen({super.key});

  @override
  State<InterestsScreen> createState() => _InterestsScreenState();
}

class _InterestsScreenState extends State<InterestsScreen> {
  late final Set<String> _selected = <String>{
    ...?context.read<SessionController>().user?.interests,
  };

  Future<void> _save() async {
    await context.read<SessionController>().submitInterests(_selected.toList(growable: false));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.watch<SessionController>();
    final lang = session.user?.language ?? Localizations.localeOf(context).languageCode;
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
                  onPressed: busy ? null : session.skipInterests,
                  child: Text(l10n.interestsSkip),
                ),
              ),
              Text(l10n.interestsTitle, style: AppText.title),
              const SizedBox(height: AppSpace.sm),
              Text(
                l10n.interestsBody,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpace.md),
              Expanded(
                child: ListView(
                  children: [
                    for (final g in kInterestGroups) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.sm),
                        child: Text(g.title(lang), style: AppText.body),
                      ),
                      Wrap(
                        spacing: AppSpace.sm,
                        runSpacing: AppSpace.sm,
                        children: [
                          for (final item in g.items)
                            FilterChip(
                              label: Text(item.label(lang)),
                              selected: _selected.contains(item.id),
                              onSelected: busy
                                  ? null
                                  : (on) => setState(() {
                                        if (on) {
                                          if (_selected.length < kMaxInterests) _selected.add(item.id);
                                        } else {
                                          _selected.remove(item.id);
                                        }
                                      }),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                child: Text(
                  l10n.interestsCount(_selected.length.toString(), kMaxInterests.toString()),
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              ),
              FilledButton(
                onPressed: (_selected.isEmpty || busy) ? null : _save,
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onPrimary),
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
}
