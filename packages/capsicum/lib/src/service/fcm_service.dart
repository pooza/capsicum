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

  /// FCM の一過性エラー（`MISSING_INSTANCEID_SERVICE` /
  /// `SERVICE_NOT_AVAILABLE`）に対して指数バックオフで再試行する間隔。
  /// Play 開発者サービスの初期化遅延・ネットワーク瞬断・Google 側一時障害で
  /// 発生し、Firebase 公式が retry 推奨としているもの。
  static const _transientRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  static Future<String?> _getTokenWithRecovery(
    FirebaseMessaging messaging,
  ) async {
    try {
      return await messaging.getToken();
    } on FirebaseException catch (e) {
      if (_isTooManyRegistrations(e)) {
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
      if (isTransient(e)) {
        return await _getTokenWithBackoff(messaging, initialError: e);
      }
      rethrow;
    }
  }

  static Future<String?> _getTokenWithBackoff(
    FirebaseMessaging messaging, {
    required FirebaseException initialError,
  }) async {
    var lastError = initialError;
    for (var attempt = 0; attempt < _transientRetryDelays.length; attempt++) {
      final delay = _transientRetryDelays[attempt];
      debugPrint(
        'capsicum: push.fcm: ${lastError.message ?? lastError.code}; '
        'retry ${attempt + 1}/${_transientRetryDelays.length} in ${delay.inSeconds}s',
      );
      await Future<void>.delayed(delay);
      try {
        return await messaging.getToken();
      } on FirebaseException catch (e) {
        if (!isTransient(e)) rethrow;
        lastError = e;
      }
    }
    // 全リトライ消化。最後に観測したエラーを上位に返し、initialize() の
    // catch 経由で Sentry に送る（恒常的な障害として記録）。
    throw lastError;
  }

  /// FCM の `TOO_MANY_REGISTRATIONS` エラーかどうかを判定。
  ///
  /// firebase_messaging plugin は code を `firebase_messaging/unknown` で
  /// 丸めてしまうため、message に頼ってマッチさせる。
  static bool _isTooManyRegistrations(Object e) {
    if (e is! FirebaseException) return false;
    return e.message?.contains('TOO_MANY_REGISTRATIONS') ?? false;
  }

  /// FCM の transient エラーかどうかを判定。`MISSING_INSTANCEID_SERVICE` /
  /// `SERVICE_NOT_AVAILABLE` は Play 開発者サービスの初期化遅延・ネットワーク
  /// 瞬断・Google 側一時障害で発生する一過性エラーとして公式が retry 推奨。
  /// PushRegistrationService._isTransient からも参照される。
  static bool isTransient(Object e) {
    if (e is! FirebaseException) return false;
    final message = e.message;
    if (message == null) return false;
    return message.contains('MISSING_INSTANCEID_SERVICE') ||
        message.contains('SERVICE_NOT_AVAILABLE');
  }
}
