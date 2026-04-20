import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// FCM デバイストークンを取得・管理するサービス。
///
/// APNs の [ApnsService] と対になる Android 向けの実装。
/// トークンは [PushRegistrationService] がリレーサーバーへの登録に使用する。
class FcmService {
  static String? _deviceToken;
  static final _tokenController = StreamController<String>.broadcast();

  /// 最新の FCM デバイストークン。未取得なら `null`。
  static String? get deviceToken => _deviceToken;

  /// トークン更新時に発火するストリーム。
  static Stream<String> get onTokenChanged => _tokenController.stream;

  /// FCM を初期化しトークンを取得する。アプリ起動時に1回呼ぶ。
  static Future<void> initialize() async {
    try {
      final messaging = FirebaseMessaging.instance;

      // 通知権限のリクエスト（Android 13+ で必要）
      final settings = await messaging.requestPermission();
      debugPrint('capsicum: FCM permission: ${settings.authorizationStatus}');

      // トークン取得
      final token = await messaging.getToken();
      if (token != null) {
        _deviceToken = token;
        _tokenController.add(token);
        debugPrint('capsicum: FCM token received (${token.length} chars)');
      } else {
        debugPrint('capsicum: FCM getToken returned null');
      }

      // トークン更新の監視
      messaging.onTokenRefresh.listen((token) {
        _deviceToken = token;
        _tokenController.add(token);
      });
    } catch (e, st) {
      debugPrint('capsicum: FCM initialization failed: $e');
      Sentry.captureException(
        e,
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('service', 'fcm_init');
        },
      );
    }
  }
}
