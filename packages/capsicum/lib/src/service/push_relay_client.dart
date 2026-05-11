import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../constants.dart';

/// capsicum-relay サーバーとの通信クライアント。
///
/// リレーサーバーにデバイストークンを登録し、Web Push の受信エンドポイントを
/// 取得する。リレーサーバーは受信した Web Push を APNs / FCM に変換して転送する。
class PushRelayClient {
  static const relayBaseUrl = 'https://relay.capsicum.shrieker.net';
  static const _secret = String.fromEnvironment('RELAY_SECRET');

  /// register リトライ間隔。fcm_service の `_transientRetryDelays` と同じ
  /// 2s / 5s / 15s カーブ。splash 起動直後のネットワーク準備中失敗 (#480)
  /// を吸収するため。
  static const _registerRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  final _dio = Dio(
    BaseOptions(
      baseUrl: relayBaseUrl,
      connectTimeout: kPushRelayConnectTimeout,
      receiveTimeout: kPushRelayReceiveTimeout,
    ),
  );

  /// デバイストークンをリレーサーバーに登録する。
  ///
  /// 戻り値に `id`（登録解除用）と `push_token`（Web Push エンドポイント構築用）
  /// が含まれる。同一デバイストークンでの再登録は既存レコードを更新し、
  /// `push_token` は維持される。
  ///
  /// 接続段階のエラー (`unknown` / `connectionError` / `connectionTimeout` /
  /// `sendTimeout` / `receiveTimeout`) は transient とみなして指数バックオフで
  /// 自動リトライする (#480)。Splash 起動直後にネットワーク準備が整う前に
  /// 一斉実行されて失敗する Sentry CAPSICUM-10 系列の発生を抑える。
  /// 4xx / 5xx (`badResponse`) はリトライせずそのまま rethrow。
  Future<Map<String, dynamic>> register({
    required String token,
    required String deviceType,
    required String account,
    required String server,
  }) async {
    DioException? lastError;
    for (var attempt = 0; attempt <= _registerRetryDelays.length; attempt++) {
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          '/register',
          data: {
            'token': token,
            'device_type': deviceType,
            'account': account,
            'server': server,
          },
          options: Options(headers: {'X-Relay-Secret': _secret}),
        );
        if (attempt > 0) {
          _breadcrumb(
            'register succeeded after retry',
            data: {'attempt': attempt, 'server': server},
            level: SentryLevel.info,
          );
        }
        return response.data!;
      } on DioException catch (e) {
        lastError = e;
        if (!_isTransientNetwork(e) ||
            attempt >= _registerRetryDelays.length) {
          rethrow;
        }
        final delay = _registerRetryDelays[attempt];
        _breadcrumb(
          'register transient, retrying',
          data: {
            'attempt': attempt + 1,
            'max': _registerRetryDelays.length,
            'delay_ms': delay.inMilliseconds,
            'type': e.type.name,
            'status': e.response?.statusCode,
            'server': server,
          },
          level: SentryLevel.warning,
        );
        debugPrint(
          'capsicum: push.relay: register transient (${e.type.name}); '
          'retry ${attempt + 1}/${_registerRetryDelays.length} in '
          '${delay.inSeconds}s',
        );
        await Future<void>.delayed(delay);
      }
    }
    // ここに到達するのは _registerRetryDelays が空のときのみ (現状起こらない)。
    throw lastError ??
        DioException(
          requestOptions: RequestOptions(path: '/register'),
          type: DioExceptionType.unknown,
          message: 'register exhausted retries with no error captured',
        );
  }

  /// リレーサーバーからデバイストークン登録を解除する。
  Future<void> unregister(int id) async {
    await _dio.delete(
      '/register/$id',
      options: Options(headers: {'X-Relay-Secret': _secret}),
    );
  }

  /// 接続段階の transient エラーか判定する。`badResponse` (4xx/5xx) は
  /// サーバー応答が返っている = 接続自体は成立しているので transient 扱い
  /// しない (notSupported 系のセマンティック扱いに任せる)。
  static bool _isTransientNetwork(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.unknown:
        return true;
      case DioExceptionType.badResponse:
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
        return false;
    }
  }

  static void _breadcrumb(
    String message, {
    Map<String, Object?> data = const {},
    SentryLevel level = SentryLevel.info,
  }) {
    try {
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'push.relay',
          level: level,
          message: message,
          data: data,
        ),
      );
    } catch (_) {
      // Sentry 未初期化等で本筋を止めない。
    }
  }
}
