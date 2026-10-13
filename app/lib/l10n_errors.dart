import 'l10n/app_localizations.dart';

/// Ánh xạ mã lỗi → chuỗi dịch – DESIGN.md §5. Không bao giờ dùng `message` của server.
String errorText(AppLocalizations l, String code) {
  switch (code) {
    case 'UNAUTHENTICATED':
      return l.errorSessionExpired;
    case 'RATE_LIMITED':
      return l.errorRateLimited;
    case 'ACCOUNT_BANNED':
      return l.errorBanned;
    case 'SESSION_REPLACED':
      return l.errorSessionReplaced;
    case 'CALL_PROVIDER_ERROR':
      return l.errorCallUnavailable;
    case 'PEER_ANOMALY':
      return l.peerAnomalyBody;
    case 'SHIELD_PAUSE':
      return l.errorShieldPause;
    case 'SWIPE_RELAY_SKIPPED':
      return l.swipeRelaySkipped;
    case 'SWIPE_WEAK_STOPPED':
      return l.swipeWeakStopped;
    case 'CALL_RELAY_SLOW':
      return l.callRelaySlow;
    case 'CALL_RELAY_VERY_SLOW':
      return l.callRelayVerySlow;
    case 'CALL_RECONNECTING':
      return l.callReconnecting;
    case 'CALL_RECONNECTED':
      return l.callReconnected;
    case 'CALL_P2P_RESTORED':
      return l.callP2pRestored;
    case 'NETWORK_POOR':
      return l.errorNetworkPoor;
    case 'NETWORK':
      return l.errorNetwork;
    case 'CONTACT_LIMIT':
      return l.errorContactLimit;
    case 'CONTACT_NOT_FOUND':
      return l.errorContactNotFound;
    case 'FEATURE_DISABLED':
      return l.errorFeatureDisabled;
    case 'PERMISSION_DENIED':
      return l.errorPermissionDenied;
    case 'INSUFFICIENT_POINTS':
      return l.errorInsufficientPoints;
    case 'GIFT_NOT_FOUND':
      return l.errorGiftExpired;
    case 'NOT_YOUR_TURN':
      return l.errorNotYourTurn;
    case 'ILLEGAL_MOVE':
      return l.errorIllegalMove;
    case 'GAME_ALREADY_ACTIVE':
      return l.errorGameActive;
    case 'GAME_NOT_FOUND':
      return l.errorGameGone;
    // IDEMPOTENCY_CONFLICT, INVITE_*, INVALID_STATE...: không có chuỗi riêng → errorGeneric.
    default:
      return l.errorGeneric;
  }
}
