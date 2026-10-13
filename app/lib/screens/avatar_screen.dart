import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/media_pick_guard.dart';
import 'package:provider/provider.dart';

import '../models/avatar.dart';
import '../models/api_error.dart';
import '../services/api_client.dart';
import '../state/avatar_cache.dart';
import '../state/session_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';
import '../widgets/user_avatar.dart';

/// Chọn ảnh đại diện: ảnh có sẵn, ảnh từ thư viện (thu nhỏ 160 px, JPEG ≤ 24 KB) hoặc xóa.
class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});

  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<Avatar?> Function(ApiClient api) action, String selfId) async {
    final api = context.read<ApiClient>();
    final cache = context.read<AvatarCache>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final a = await action(api);
      cache.set(selfId, a);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code);
    } on Object {
      if (mounted) setState(() => _error = 'ERROR');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickPhoto(String selfId) async {
    final picked = await MediaPickGuard.run(() => ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 160,
          maxHeight: 160,
          imageQuality: 70,
        ));
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    await _run((api) => api.uploadAvatar(bytes), selfId);
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<SessionController>().user;
    final selfId = user?.id ?? '';
    final cache = context.watch<AvatarCache>();
    final current = selfId.isEmpty ? null : cache.of(selfId);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(tr(context, 'Ảnh đại diện', 'Profile picture'), style: AppText.label),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Center(child: AvatarView(userId: selfId, name: user?.displayName ?? '', avatar: current, size: 96)),
          const SizedBox(height: AppSpace.lg),
          FilledButton.icon(
            onPressed: _busy || selfId.isEmpty ? null : () => unawaited(_pickPhoto(selfId)),
            icon: const Icon(Icons.photo_library_rounded),
            label: Text(tr(context, 'Chọn ảnh từ thư viện', 'Choose from gallery')),
          ),
          const SizedBox(height: AppSpace.md),
          OutlinedButton(
            onPressed: _busy || selfId.isEmpty
                ? null
                : () => unawaited(_run((api) async {
                      await api.deleteAvatar();
                      return null;
                    }, selfId)),
            child: Text(tr(context, 'Xóa ảnh', 'Remove picture')),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.md),
              child: Text(
                tr(context, 'Không lưu được ảnh ($_error). Thử ảnh khác hoặc kiểm tra mạng.', 'Could not save the picture ($_error).'),
                style: AppText.caption.copyWith(color: AppColors.danger),
              ),
            ),
          const SizedBox(height: AppSpace.xl),
          Text(tr(context, 'Hoặc chọn ảnh có sẵn', 'Or pick a preset'), style: AppText.label),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.md,
            children: [
              for (final id in kPresetAvatarIds)
                PresetAvatarTile(
                  id: id,
                  selected: current?.isPreset == true && current?.presetId == id,
                  onTap: _busy || selfId.isEmpty
                      ? () {}
                      : () => unawaited(_run((api) async {
                            await api.updateMe(avatarPreset: id);
                            return Avatar.preset(id);
                          }, selfId)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
