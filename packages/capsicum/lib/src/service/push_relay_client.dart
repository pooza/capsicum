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
  }) {
    return _postWithRetry(
      path: '/register',
      operation: 'register',
      data: {
        'token': token,
        'device_type': deviceType,
        'account': account,
        'server': server,
      },
      server: server,
    );
  }

  /// リレーサーバーからデバイストークン登録を解除する。
  Future<void> unregister(int id) async {
    await _dio.delete(
      '/register/$id',
      options: Options(headers: {'X-Relay-Secret': _secret}),
    );
  }

  /// お知らせ通知の subscription をリレーに登録する (#477)。
  ///
  /// `pushToken` は [register] が返した値 (Web Push エンドポイント末尾の
  /// device-scoped token) を渡す。リレー側で FK 制約を持っているため、
  /// 親 subscription が存在しないと 404 が返る。
  ///
  /// 戻り値に `id` (登録解除用) と `push_token` / `server` / `account` が
  /// 含まれる。retry は [register] と同じ transient ポリシー。
  Future<Map<String, dynamic>> registerAnnouncementSubscription({
    required String pushToken,
    required String account,
    required String server,
  }) {
    return _postWithRetry(
      path: '/announcement_subscriptions',
      operation: 'announcement_register',
      data: {'push_token': pushToken, 'account': account, 'server': server},
      server: server,
    );
  }

  /// お知らせ通知の subscription を解除する (#477)。`id` は
  /// [registerAnnouncementSubscription] が返した値。
  Future<void> unregisterAnnouncementSubscription(int id) async {
    await _dio.delete(
      '/announcement_subscriptions/$id',
      options: Options(headers: {'X-Relay-Secret': _secret}),
    );
  }

  /// 投げ銭イベントをサーバー側サポーター状態に記録する (#596 /
  /// capsicum-relay#18)。(account, server) 単位の upsert。
  ///
  /// [tippedAt] と 2 以上の [count] はローカル既存レコードの汲み上げ
  /// （バックフィル）用。省略時はサーバー側が現在時刻・1 回として扱う。
  /// retry は [register] と同じ transient ポリシー。
  Future<Map<String, dynamic>> recordSupporterTip({
    required String account,
    required String server,
    String? sku,
    DateTime? tippedAt,
    int count = 1,
  }) {
    return _postWithRetry(
      path: '/supporters/tip',
      operation: 'supporter_tip',
      data: {
        'account': account,
        'server': server,
        'sku': ?sku,
        'tipped_at': ?tippedAt?.toUtc().toIso8601String(),
        'count': count,
      },
      server: server,
    );
  }

  /// サーバー側サポーター状態を取得する (#596)。未登録 (404) は null。
  /// `first_tipped_at` 等の時刻は SQLite の `YYYY-MM-DD HH:MM:SS` (UTC)。
  Future<Map<String, dynamic>?> fetchSupporterStatus({
    required String account,
    required String server,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/supporters',
        queryParameters: {'account': account, 'server': server},
        options: Options(headers: {'X-Relay-Secret': _secret}),
      );
      return response.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null; // 未登録 = 非サポーター
      rethrow;
    }
  }

  /// リレー応答の `id` を防御的にパースする。整数・数値文字列の両方を許容し、
  /// 解釈不能なら null を返す（呼び出し側で契約違反として計装する）。
  /// register / announcement_subscriptions の両系統で共有する。
  static int? parseRelayId(Object? raw) {
    if (raw is int) return raw;
    if (raw == null) return null;
    return int.tryParse(raw.toString());
  }

  /// POST + transient retry の共通実装。register / announcement_register
  /// 等、リトライ対象の登録系 endpoint で共有する。
  Future<Map<String, dynamic>> _postWithRetry({
    required String path,
    required String operation,
    required Map<String, Object?> data,
    required String server,
  }) async {
    DioException? lastError;
    for (var attempt = 0; attempt <= _registerRetryDelays.length; attempt++) {
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          path,
          data: data,
          options: Options(headers: {'X-Relay-Secret': _secret}),
        );
        if (attempt > 0) {
          _breadcrumb(
            '$operation succeeded after retry',
            data: {'attempt': attempt, 'server': server},
            level: SentryLevel.info,
          );
        }
        return response.data!;
      } on DioException catch (e) {
        lastError = e;
        if (!_isTransientNetwork(e) || attempt >= _registerRetryDelays.length) {
          rethrow;
        }
        final delay = _registerRetryDelays[attempt];
        _breadcrumb(
          '$operation transient, retrying',
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
          'capsicum: push.relay: $operation transient (${e.type.name}); '
          'retry ${attempt + 1}/${_registerRetryDelays.length} in '
          '${delay.inSeconds}s',
        );
        await Future<void>.delayed(delay);
      }
    }
    throw lastError ??
        DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.unknown,
          message: '$operation exhausted retries with no error captured',
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
