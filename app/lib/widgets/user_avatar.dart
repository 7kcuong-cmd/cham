import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/env.dart';
import '../models/avatar.dart';
import '../state/avatar_cache.dart';
import '../theme/tokens.dart';

const List<IconData> _presetIcons = <IconData>[
  Icons.pets_rounded,
  Icons.star_rounded,
  Icons.favorite_rounded,
  Icons.bolt_rounded,
  Icons.music_note_rounded,
  Icons.sports_esports_rounded,
  Icons.local_cafe_rounded,
  Icons.rocket_launch_rounded,
  Icons.palette_rounded,
  Icons.camera_alt_rounded,
  Icons.eco_rounded,
  Icons.emoji_emotions_rounded,
];

const List<List<Color>> _presetGradients = <List<Color>>[
  [Color(0xFFFF4D73), Color(0xFFFF8A5B)],
  [Color(0xFF7F5AF0), Color(0xFF2CB1BC)],
  [Color(0xFF16A085), Color(0xFF2ECC71)],
  [Color(0xFFF39C12), Color(0xFFE74C3C)],
  [Color(0xFF3A86FF), Color(0xFF8338EC)],
  [Color(0xFFEE5A6F), Color(0xFFF29263)],
];

/// Hiển thị một [Avatar] đã biết (không tự tải).
class AvatarView extends StatelessWidget {
  const AvatarView({super.key, required this.userId, required this.name, this.avatar, this.size = 40});

  final String userId;
  final String name;
  final Avatar? avatar;
  final double size;

  @override
  Widget build(BuildContext context) {
    final a = avatar;
    Widget child;
    if (a != null && !a.isPreset) {
      child = Image.network(
        '${Env.apiBaseUrl}/v1/avatars/${Uri.encodeComponent(userId)}?v=${a.ver}',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _initial(),
      );
    } else if (a != null && a.isPreset) {
      final idx = (int.tryParse((a.presetId ?? 'p01').substring(1)) ?? 1) - 1;
      final grad = _presetGradients[idx.abs() % _presetGradients.length];
      child = DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(colors: grad)),
        child: Center(child: Icon(_presetIcons[idx.abs() % _presetIcons.length], size: size * 0.55, color: Colors.white)),
      );
    } else {
      child = _initial();
    }
    return ClipOval(child: SizedBox(width: size, height: size, child: child));
  }

  Widget _initial() {
    final ch = name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase();
    return ColoredBox(
      color: AppColors.surfaceHigh,
      child: Center(child: Text(ch, style: AppText.label.copyWith(fontSize: size * 0.42))),
    );
  }
}

/// Như [AvatarView] nhưng tự tải ảnh qua [AvatarCache] (cần Provider<AvatarCache> phía trên).
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.userId, required this.name, this.size = 40});

  final String userId;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cache = context.watch<AvatarCache>();
    return AvatarView(userId: userId, name: name, avatar: cache.of(userId), size: size);
  }
}

/// Ô chọn ảnh có sẵn.
class PresetAvatarTile extends StatelessWidget {
  const PresetAvatarTile({super.key, required this.id, required this.selected, required this.onTap});

  final String id;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? AppColors.primary : Colors.transparent, width: 2),
        ),
        child: AvatarView(userId: '', name: '', avatar: Avatar.preset(id), size: 56),
      ),
    );
  }
}

/// Như [UserAvatar] nhưng không cần Provider<AvatarCache>: thiếu thì hiện chữ cái đầu của tên.
class MaybeUserAvatar extends StatelessWidget {
  const MaybeUserAvatar({super.key, required this.userId, required this.name, this.size = 40});

  final String userId;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    try {
      final cache = context.watch<AvatarCache>();
      return AvatarView(userId: userId, name: name, avatar: cache.of(userId), size: size);
    } on Object {
      return AvatarView(userId: userId, name: name, size: size);
    }
  }
}
