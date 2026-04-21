import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
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

  /// 最新の通知権限ステータス。[initialize] の requestPermission 応答を保持し、
  /// PushRegistrationService が failure reason を permissionDenied に分岐する
  /// 判断材料として参照する。
  static AuthorizationStatus? _lastAuthStatus;

  /// 最新の FCM デバイストークン。未取得なら `null`。
  static String? get deviceToken => _deviceToken;

  /// トークン更新時に発火するストリーム。
  static Stream<String> get onTokenChanged => _tokenController.stream;

  /// [initialize] で observe した通知権限ステータス。
  static AuthorizationStatus? get lastAuthStatus => _lastAuthStatus;

  /// FCM を初期化しトークンを取得する。アプリ起動時に1回呼ぶ。
  static Future<void> initialize() async {
    try {
      final messaging = FirebaseMessaging.instance;

      // 通知権限のリクエスト（Android 13+ で必要）
      final settings = await messaging.requestPermission();
      _lastAuthStatus = settings.authorizationStatus;
      debugPrint(
        'capsicum: push.fcm: permission ${settings.authorizationStatus}',
      );

      // トークン取得。TOO_MANY_REGISTRATIONS は FCM の device-level state で、
      // 端末に紐付く古い registration を掃除すれば再取得できるため、
      // deleteToken + getToken で 1 回だけリカバーを試みる。
      final token = await _getTokenWithRecovery(messaging);
      if (token != null) {
        _deviceToken = token;
        _tokenController.add(token);
        debugPrint(
          'capsicum: push.fcm: token received (${token.length} chars)',
        );
      } else {
        debugPrint('capsicum: push.fcm: getToken returned null');
      }

      // トークン更新の監視
      messaging.onTokenRefresh.listen((token) {
        _deviceToken = token;
        _tokenController.add(token);
      });
    } catch (e, st) {
      debugPrint('capsicum: push.fcm: initialization failed: $e');
      Sentry.captureException(
        e,
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('service', 'fcm_init');
          if (_isTooManyRegistrations(e)) {
            scope.setTag('fcm.error', 'too_many_registrations');
          }
        },
      );
    }
  }

  static Future<String?> _getTokenWithRecovery(
    FirebaseMessaging messaging,
  ) async {
    try {
      return await messaging.getToken();
    } on FirebaseException catch (e) {
      if (!_isTooManyRegistrations(e)) rethrow;
      debugPrint(
        'capsicum: push.fcm: TOO_MANY_REGISTRATIONS; deleteToken + retry',
      );
      try {
        await messaging.deleteToken();
      } catch (deleteErr) {
        debugPrint('capsicum: push.fcm: deleteToken failed: $deleteErr');
        // delete 失敗は rethrow せず getToken リトライに進む。ベースの状態が
        // 既に壊れているケースでも、新規トークン発行は試す価値がある。
      }
      return await messaging.getToken();
    }
  }

  /// FCM の `TOO_MANY_REGISTRATIONS` エラーかどうかを判定。
  ///
  /// firebase_messaging plugin は code を `firebase_messaging/unknown` で
  /// 丸めてしまうため、message に頼ってマッチさせる。
  static bool _isTooManyRegistrations(Object e) {
    if (e is! FirebaseException) return false;
    return e.message?.contains('TOO_MANY_REGISTRATIONS') ?? false;
  }
}
