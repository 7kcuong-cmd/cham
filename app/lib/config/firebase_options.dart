import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
const _messagingSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
const _appIdAndroid = String.fromEnvironment('FIREBASE_APP_ID_ANDROID');
const _appIdIos = String.fromEnvironment('FIREBASE_APP_ID_IOS');
const _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');

/// Tên các biến `--dart-define` còn thiếu cho nền tảng [platform] (rỗng = đủ).
/// Tách ra để test được mà không cần Firebase.
List<String> missingFirebaseVars({
  required TargetPlatform platform,
  String apiKey = _apiKey,
  String projectId = _projectId,
  String messagingSenderId = _messagingSenderId,
  String appIdAndroid = _appIdAndroid,
  String appIdIos = _appIdIos,
  String iosBundleId = _iosBundleId,
}) {
  final missing = <String>[];
  if (apiKey.isEmpty) missing.add('FIREBASE_API_KEY');
  if (projectId.isEmpty) missing.add('FIREBASE_PROJECT_ID');
  if (messagingSenderId.isEmpty) missing.add('FIREBASE_MESSAGING_SENDER_ID');
  if (platform == TargetPlatform.iOS) {
    if (appIdIos.isEmpty) missing.add('FIREBASE_APP_ID_IOS');
    if (iosBundleId.isEmpty) missing.add('FIREBASE_IOS_BUNDLE_ID');
  } else {
    if (appIdAndroid.isEmpty) missing.add('FIREBASE_APP_ID_ANDROID');
  }
  return missing;
}

/// Dựng [FirebaseOptions] từ `--dart-define`. Thiếu biến → [StateError]
/// (lỗi cấu hình của người build, không phải chuỗi giao diện).
FirebaseOptions firebaseOptionsFromEnv() {
  final missing = missingFirebaseVars(platform: defaultTargetPlatform);
  if (missing.isNotEmpty) {
    throw StateError('Missing FIREBASE_* dart-define: ${missing.join(', ')}');
  }
  final isIos = defaultTargetPlatform == TargetPlatform.iOS;
  return FirebaseOptions(
    apiKey: _apiKey,
    appId: isIos ? _appIdIos : _appIdAndroid,
    messagingSenderId: _messagingSenderId,
    projectId: _projectId,
    iosBundleId: isIos ? _iosBundleId : null,
  );
}
