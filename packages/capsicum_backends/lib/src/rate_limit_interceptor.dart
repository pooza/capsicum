import 'dart:math';

import 'package:dio/dio.dart';

/// Dio interceptor that retries requests on 429 (Too Many Requests) responses.
///
/// Uses `Retry-After` header when available, otherwise falls back to
/// exponential backoff with jitter.
class RateLimitInterceptor extends Interceptor {
  static const _maxRetries = 3;
  static const _baseDelay = Duration(seconds: 1);
  static const _retryCountKey = 'rateLimitRetryCount';

  final Dio _dio;
  final Random _random = Random();

  RateLimitInterceptor(this._dio);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
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
