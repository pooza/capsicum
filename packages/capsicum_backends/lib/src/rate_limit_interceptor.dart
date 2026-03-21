import 'dart:math';

import 'package:dio/dio.dart';

/// Dio interceptor that handles API rate limiting.
///
/// - Parses `X-RateLimit-Remaining` / `X-RateLimit-Reset` headers and
///   preemptively delays requests when the remaining quota is low.
/// - Retries on 429 responses using `Retry-After` header or exponential
///   backoff with jitter.
class RateLimitInterceptor extends Interceptor {
  static const _maxRetries = 3;
  static const _baseDelay = Duration(seconds: 1);
  static const _retryCountKey = 'rateLimitRetryCount';

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
      RequestOptions options, RequestInterceptorHandler handler) async {
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

    final delay = _calculateDelay(response!, retryCount);
    _retry(err, handler, retryCount, delay);
  }

  void _parseRateLimitHeaders(Headers headers) {
    final remainingStr = headers.value('x-ratelimit-remaining');
    if (remainingStr != null) {
      _remaining = int.tryParse(remainingStr);
    }

    final resetStr = headers.value('x-ratelimit-reset');
    if (resetStr != null) {
      _resetAt = DateTime.tryParse(resetStr);
    }
  }

  Duration _calculateDelay(Response response, int retryCount) {
    final retryAfter = response.headers.value('retry-after');
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter);
      if (seconds != null) {
        return Duration(seconds: seconds);
      }
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

    try {
      final response = await _dio.fetch(options);
      handler.resolve(response);
    } on DioException catch (e) {
      onError(e, handler);
    }
  }
}
