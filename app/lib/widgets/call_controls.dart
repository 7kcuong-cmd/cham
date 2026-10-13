import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/tokens.dart';
import 'edge_actions.dart';

/// Nút tắt/bật mic và camera, góc dưới trái (DESIGN.md S3).
class CallControls extends StatelessWidget {
  const CallControls({
    super.key,
    required this.micOn,
    required this.camOn,
    required this.onToggleMic,
    required this.onToggleCamera,
  });

  final bool micOn;
  final bool camOn;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        EdgeButton(
          icon: micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
          tooltip: micOn ? l10n.a11yMute : l10n.a11yUnmute,
          iconColor: micOn ? AppColors.textPrimary : AppColors.danger,
          onPressed: onToggleMic,
        ),
        const SizedBox(width: AppSpace.sm),
        EdgeButton(
          icon: camOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
          tooltip: camOn ? l10n.a11yCameraOff : l10n.a11yCameraOn,
          iconColor: camOn ? AppColors.textPrimary : AppColors.danger,
          onPressed: onToggleCamera,
        ),
      ],
    );
  }
}
