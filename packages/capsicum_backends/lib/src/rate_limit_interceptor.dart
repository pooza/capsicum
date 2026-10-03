import 'dart:math';

import 'package:dio/dio.dart';

/// Dio interceptor that handles API rate limiting.
///
/// - Parses `X-RateLimit-Remaining` / `X-RateLimit-Reset` headers and
///   preemptively delays requests when the remaining quota is low.
/// - Retries on 429 responses using `Retry-After`, then `X-RateLimit-Reset`,
///   then exponential backoff with jitter.
class RateLimitInterceptor extends Interceptor {
  static const _maxRetries = 3;
  static const _baseDelay = Duration(seconds: 1);
  static const _retryCountKey = 'rateLimitRetryCount';

  /// `Retry-After` が無い 429 で `X-RateLimit-Reset` を待つ上限 (#1103)。
  ///
  /// ⚠⚠ **Mastodon は 429 に `Retry-After` を付けず、`X-RateLimit-Reset`
  /// （ISO 8601）だけを返す。**ヘッダは読めていたのに遅延の計算に使っておらず、
  /// **指数バックオフ（合計 1〜7 秒）で 3 回とも窓の中に打ち返して尽きていた**。
  /// モロヘイヤも 5.39.0 からこのヘッダを透過時に中継する（mulukhiya#4775）。
  ///
  /// ⚠ **上限を置くのは、窓が分単位だから。**Mastodon の窓は 5 分なので、
  /// 素直に待つと**投稿ボタンが数分固まる**。⚠⚠ **上限を超えたら「待たずに
  /// 諦める」**（バックオフへ落とさない）—— 窓が明けていないと分かっている
  /// ところへ打ち返すのは、サーバーにも利用者にも無駄だから。呼び出し側は
  /// 429 をそのまま受け取り、利用者に伝えて終われる。
  static const _maxResetWait = Duration(seconds: 60);

  /// `X-RateLimit-Reset` として受け入れる最大の先 (#1103)。これを超える値は
  /// **読めなかったものとして捨てる**。
  ///
  /// ⚠⚠ **`DateTime.tryParse('1790000000')` は null にならない。**epoch 秒を
  /// 返すサーバー（GitHub 風）の値が **compact ISO として「西暦 178999 年」に
  /// 解釈される**（2026-10-01 に実測）。そのまま信じると:
  ///
  /// - 先回りの待機（[onRequest]）が **17 万年待つ＝事実上その要求が永久に
  ///   返らない**
  /// - 429 の再試行は「窓が遠すぎる」と判断して**常に諦める**
  ///
  /// ⚠ **レート制限の窓は長くても時間単位**（Mastodon は 5 分）なので、
  /// これを超えるものは桁か形式の取り違えとみなす。
  static const _maxPlausibleReset = Duration(hours: 1);

  /// Key for a `Future<FormData> Function()` stored in [RequestOptions.extra].
  /// When present, the interceptor uses this factory to rebuild FormData
  /// (whose streams are consumed after the first send) before retrying a 429.
  static const formDataFactoryKey = 'formDataFactory';

  /// When remaining requests fall to this threshold or below, preemptively
  /// wait until the reset time before sending the next request.
  static const _remainingThreshold = 3;

  final Dio _dio;
  final Random _random;

  DateTime? _resetAt;
  int? _remaining;

  RateLimitInterceptor(this._dio, {Random? random})
    : _random = random ?? Random();

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _parseRateLimitHeaders(response.headers);
    handler.next(response);
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Skip preemptive wait for retry requests (already delayed).
    if ((options.extra[_retryCountKey] as int? ?? 0) > 0) {
      return handler.next(options);
    }

    final remaining = _remaining;
    final resetAt = _resetAt;
    if (remaining != null &&
        remaining <= _remainingThreshold &&
        resetAt != null) {
      final now = DateTime.now();
      if (resetAt.isAfter(now)) {
        await Future<void>.delayed(resetAt.difference(now));
        // Clear after waiting so we don't block subsequent requests.
        _remaining = null;
        _resetAt = null;
      }
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response != null) {
      _parseRateLimitHeaders(err.response!.headers);
    }

    final response = err.response;
    if (response?.statusCode != 429) {
      return handler.next(err);
    }

    final retryCount = err.requestOptions.extra[_retryCountKey] as int? ?? 0;
    if (retryCount >= _maxRetries) {
      return handler.next(err);
    }

    // FormData with files contains consumed streams that cannot be re-read.
    // If a factory is provided we can rebuild it; otherwise skip retry.
    if (err.requestOptions.data is FormData &&
        err.requestOptions.extra[formDataFactoryKey] == null) {
      return handler.next(err);
    }

    final delay = _calculateDelay(response!, retryCount);
    // ⚠ 窓が明けるのが [_maxResetWait] より先なら、待たずに諦める (#1103)。
    if (delay == null) return handler.next(err);
    _retry(err, handler, retryCount, delay);
  }

  void _parseRateLimitHeaders(Headers headers) {
    final remainingStr = headers.value('x-ratelimit-remaining');
    if (remainingStr != null) {
      _remaining = int.tryParse(remainingStr);
    }

    final resetStr = headers.value('x-ratelimit-reset');
    if (resetStr != null) {
      _resetAt = _parseResetAt(resetStr);
    }
  }

  /// `X-RateLimit-Reset` を読む。**妥当でない値は null** (#1103)。
  ///
  /// ⚠⚠ **`DateTime.tryParse` に素で通さない。**epoch 秒は null にならず
  /// 「西暦 178999 年」として通るので、[_maxPlausibleReset] より先のものは
  /// 捨てる（理由は定数の doc）。
  DateTime? _parseResetAt(String? raw) {
    final parsed = DateTime.tryParse(raw ?? '');
    if (parsed == null) return null;
    if (parsed.difference(DateTime.now()) > _maxPlausibleReset) return null;
    return parsed;
  }

  /// 429 を受けてから再試行するまでの待ち時間。**null は「待たずに諦める」**。
  ///
  /// 優先順は `Retry-After` → `X-RateLimit-Reset` → 指数バックオフ (#1103)。
  Duration? _calculateDelay(Response response, int retryCount) {
    final retryAfter = response.headers.value('retry-after');
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter);
      if (seconds != null) {
        return Duration(seconds: seconds);
      }
    }

    // ⚠⚠ **Mastodon の 429 には `Retry-After` が無い (#1103)。**窓が明ける時刻は
    // `X-RateLimit-Reset`（ISO 8601）だけが持っている。これを見ないと、分単位の
    // 窓に対して秒単位のバックオフで打ち返し、3 回とも 429 で尽きる。
    //
    // ⚠ **[_resetAt]（共有フィールド）ではなく、この応答のヘッダを読む。**
    // あちらは別の要求が入れた値が残っていることがあり、**関係の無い窓を待つ**
    // ことになる。
    final resetAt = _parseResetAt(response.headers.value('x-ratelimit-reset'));
    if (resetAt != null) {
      final wait = resetAt.difference(DateTime.now());
      // ⚠ 長すぎる窓は待たずに諦める（UI が数分固まるのを避ける）。
      if (wait > _maxResetWait) return null;
      // ⚠ 既に明けている（負 / 0）ならバックオフへ落とす。サーバーが過去の
      // 時刻を返しているか、待っているあいだに明けた場合。
      if (wait > Duration.zero) return wait;
    }

    // Exponential backoff with jitter.
    final backoff = _baseDelay.inMilliseconds * pow(2, retryCount);
    final jitter = _random.nextInt(backoff.toInt());
    return Duration(milliseconds: backoff.toInt() + jitter);
  }

  void _retry(
    DioException err,
    ErrorInterceptorHandler handler,
    int retryCount,
    Duration delay,
  ) async {
    await Future<void>.delayed(delay);

    final options = err.requestOptions;
    options.extra[_retryCountKey] = retryCount + 1;

    // Rebuild FormData from factory so file streams are fresh.
    final factory = options.extra[formDataFactoryKey];
    if (factory != null && options.data is FormData) {
      options.data = await (factory as Future<FormData> Function())();
    }

    try {
      final response = await _dio.fetch(options);
      handler.resolve(response);
    } on DioException catch (e) {
      onError(e, handler);
    }
  }
}
