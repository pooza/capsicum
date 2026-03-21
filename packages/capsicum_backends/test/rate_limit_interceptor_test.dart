import 'dart:math';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:capsicum_backends/src/rate_limit_interceptor.dart';

class _FixedRandom extends Mock implements Random {
  @override
  int nextInt(int max) => 0; // No jitter for deterministic tests.
}

/// A mock HTTP adapter that returns pre-configured responses.
class _MockAdapter implements HttpClientAdapter {
  final List<_MockResponse> _responses = [];
  int callCount = 0;

  void enqueue(int statusCode, {Map<String, List<String>>? headers}) {
    _responses.add(_MockResponse(statusCode, headers ?? {}));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    final mock = _responses.removeAt(0);
    if (mock.statusCode >= 400) {
      throw DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: mock.statusCode,
          headers: Headers.fromMap(mock.headers),
        ),
        type: DioExceptionType.badResponse,
      );
    }
    return ResponseBody.fromString(
      '{}',
      mock.statusCode,
      headers: mock.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MockResponse {
  final int statusCode;
  final Map<String, List<String>> headers;
  _MockResponse(this.statusCode, this.headers);
}

void main() {
  late Dio dio;
  late _MockAdapter adapter;
  late RateLimitInterceptor interceptor;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
    adapter = _MockAdapter();
    dio.httpClientAdapter = adapter;
    interceptor = RateLimitInterceptor(dio, random: _FixedRandom());
    dio.interceptors.add(interceptor);
  });

  group('RateLimitInterceptor', () {
    test('passes through non-429 errors', () async {
      adapter.enqueue(500);

      expect(
        () => dio.get('/test'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
    });

    test('retries on 429 and succeeds', () async {
      adapter.enqueue(
        429,
        headers: {
          'retry-after': ['1'],
        },
      );
      adapter.enqueue(200);

      final response = await dio.get('/test');
      expect(response.statusCode, 200);
      expect(adapter.callCount, 2);
    });

    test('respects Retry-After header', () async {
      adapter.enqueue(
        429,
        headers: {
          'retry-after': ['1'],
        },
      );
      adapter.enqueue(200);

      final stopwatch = Stopwatch()..start();
      await dio.get('/test');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
    });

    test('gives up after max retries', () async {
      // 4 responses: initial + 3 retries = all 429.
      for (var i = 0; i < 4; i++) {
        adapter.enqueue(429);
      }

      expect(
        () => dio.get('/test'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'statusCode',
            429,
          ),
        ),
      );
    });

    test('uses exponential backoff without Retry-After', () async {
      adapter.enqueue(429); // No Retry-After → 1s backoff (jitter=0)
      adapter.enqueue(200);

      final stopwatch = Stopwatch()..start();
      await dio.get('/test');
      stopwatch.stop();

      // Base delay is 1s, retry 0 → 1s * 2^0 = 1s, jitter = 0.
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
    });

    test('parses X-RateLimit-Remaining and X-RateLimit-Reset', () async {
      final resetTime = DateTime.now()
          .add(const Duration(seconds: 2))
          .toUtc()
          .toIso8601String();
      adapter.enqueue(
        200,
        headers: {
          'x-ratelimit-remaining': ['2'],
          'x-ratelimit-reset': [resetTime],
        },
      );
      // First request succeeds and populates rate limit state.
      await dio.get('/first');

      // Second request should be delayed because remaining <= threshold.
      adapter.enqueue(200);
      final stopwatch = Stopwatch()..start();
      await dio.get('/second');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(1000));
    });

    test('does not delay when remaining is above threshold', () async {
      final resetTime = DateTime.now()
          .add(const Duration(seconds: 5))
          .toUtc()
          .toIso8601String();
      adapter.enqueue(
        200,
        headers: {
          'x-ratelimit-remaining': ['100'],
          'x-ratelimit-reset': [resetTime],
        },
      );
      await dio.get('/first');

      adapter.enqueue(200);
      final stopwatch = Stopwatch()..start();
      await dio.get('/second');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });
  });
}
