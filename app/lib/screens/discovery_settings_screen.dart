import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/api_error.dart';
import '../models/discovery.dart';
import '../services/api_client.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// Cho phép người khác tìm mình bằng email / số điện thoại (khớp đúng) / tên (mặc định TẮT).
class DiscoverySettingsScreen extends StatefulWidget {
  const DiscoverySettingsScreen({super.key});

  @override
  State<DiscoverySettingsScreen> createState() => _DiscoverySettingsScreenState();
}

class _DiscoverySettingsScreenState extends State<DiscoverySettingsScreen> {
  DiscoveryPrefs? _prefs;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final p = await context.read<ApiClient>().getDiscovery();
      if (mounted) setState(() => _prefs = p);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code);
    }
  }

  Future<void> _set({bool? email, bool? phone, bool? name}) async {
    try {
      final p = await context.read<ApiClient>().setDiscovery(byEmail: email, byPhone: phone, byName: name);
      if (mounted) setState(() => _prefs = p);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(AppLocalizations.of(context), e.code))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _prefs;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Cho phép người khác tìm bạn', 'Let others find you'))),
      body: _error != null
          ? Center(child: Text(errorText(AppLocalizations.of(context), _error!)))
          : p == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    SwitchListTile(
                      title: Text(tr(context, 'Tìm bằng email', 'Find me by email')),
                      subtitle: Text(tr(context, 'Chỉ khi họ gõ đúng email của bạn.', 'Only if they type your exact email.')),
                      value: p.byEmail,
                      onChanged: (v) => unawaited(_set(email: v)),
                    ),
                    SwitchListTile(
                      title: Text(tr(context, 'Tìm bằng số điện thoại', 'Find me by phone number')),
                      subtitle: Text(tr(context, 'Cần đã xác minh số điện thoại. Chỉ khớp đúng số.', 'Requires a verified phone. Exact match only.')),
                      value: p.byPhone,
                      onChanged: (v) => unawaited(_set(phone: v)),
                    ),
                    SwitchListTile(
                      title: Text(tr(context, 'Tìm bằng tên', 'Find me by name')),
                      subtitle: Text(tr(context, 'Tên hiển thị của bạn sẽ xuất hiện khi người lạ tìm tên.', 'Your display name will show up when strangers search names.')),
                      value: p.byName,
                      onChanged: (v) => unawaited(_set(name: v)),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpace.lg),
                      child: Text(
                        tr(context, 'Dù tìm thấy, người lạ vẫn phải được bạn chấp nhận mới thành bạn. Người bạn đã chặn không bao giờ tìm thấy bạn.',
                            'Even when found, strangers must be accepted by you to become contacts. People you blocked never find you.'),
                        style: AppText.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
    );
  }
}
