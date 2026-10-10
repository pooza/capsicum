import 'dart:math';

import 'package:capsicum_backends/src/rate_limit_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

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

    // #1237: 残りが閾値以下でも、窓が遠ければ待たない。以前は窓が明けるまで
    // 黙って待っていた（Mastodon の 5 分窓なら最大約 5 分・読み込み中のまま固まる）。
    test('⚠⚠ 窓が遠いときは、先回りで待たずに送る', () async {
      final resetTime = DateTime.now()
          .add(const Duration(minutes: 5))
          .toUtc()
          .toIso8601String();
      adapter.enqueue(
        200,
        headers: {
          'x-ratelimit-remaining': ['2'],
          'x-ratelimit-reset': [resetTime],
        },
      );
      await dio.get('/first');

      adapter.enqueue(200);
      final stopwatch = Stopwatch()..start();
      await dio.get('/second');
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(500),
        reason: '⚠ 待っていたら 5 分返らない（テストはタイムアウトで落ちる）',
      );
      expect(adapter.callCount, 2, reason: '要求そのものは送っている');
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

  /// #1103: `Retry-After` が無い 429 で `X-RateLimit-Reset` を見る。
  ///
  /// ⚠⚠ **Mastodon は 429 に `Retry-After` を付けない。**窓が明ける時刻は
  /// `X-RateLimit-Reset`（ISO 8601）だけが持っているのに、遅延の計算では読んで
  /// いなかった。**分単位の窓に対して秒単位のバックオフで打ち返し、3 回とも
  /// 429 で尽きていた。**モロヘイヤも 5.39.0 からこのヘッダを透過時に中継する
  /// （mulukhiya#4775）ので、経由しても経由しなくても同じ形で来る。
  group('X-RateLimit-Reset で待つ (#1103)', () {
    String resetIn(Duration d) =>
        DateTime.now().add(d).toUtc().toIso8601String();

    test('⚠⚠ Retry-After が無くても、窓が明けるまで待って再試行する', () async {
      adapter.enqueue(
        429,
        headers: {
          'x-ratelimit-reset': [resetIn(const Duration(seconds: 2))],
        },
      );
      adapter.enqueue(200);

      final stopwatch = Stopwatch()..start();
      await dio.get('/test');
      stopwatch.stop();

      // ⚠ バックオフだと 1 秒（jitter 0）で打ち返す。窓を見ていれば約 2 秒。
      expect(
        stopwatch.elapsedMilliseconds,
        greaterThanOrEqualTo(1500),
        reason: 'バックオフ（1 秒）ではなく、窓が明けるまで待つ',
      );
      expect(adapter.callCount, 2);
    });

    test('⚠ Retry-After があればそちらが優先（既存の挙動を崩さない）', () async {
      adapter.enqueue(
        429,
        headers: {
          'retry-after': ['1'],
          // ⚠ こちらを見てしまうと 5 秒待つことになる。
          'x-ratelimit-reset': [resetIn(const Duration(seconds: 5))],
        },
      );
      adapter.enqueue(200);

      final stopwatch = Stopwatch()..start();
      await dio.get('/test');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
      expect(stopwatch.elapsedMilliseconds, lessThan(3000));
    });

    // ⚠⚠ **ここが「待たない」側の歯。**Mastodon の窓は 5 分なので、素直に待つと
    // 投稿ボタンが数分固まる。⚠ **バックオフへ落とさない**（窓が明けていないと
    // 分かっているところへ打ち返すのは無駄）。
    test('⚠⚠ 窓が遠すぎたら待たずに諦める（打ち返しもしない）', () async {
      adapter.enqueue(
        429,
        headers: {
          'x-ratelimit-reset': [resetIn(const Duration(minutes: 5))],
        },
      );

      final stopwatch = Stopwatch()..start();
      await expectLater(
        dio.get('/test'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'statusCode',
            429,
          ),
        ),
      );
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(500),
        reason: '待たずにその場で返す',
      );
      expect(adapter.callCount, 1, reason: '⚠ バックオフで打ち返さない（レート制限中のサーバーを叩かない）');
    });

    // 既に明けている時刻（サーバーが過去を返す / 待つうちに明けた）は、
    // 従来どおりバックオフへ落とす。
    test('⚠ 過去の reset はバックオフへ落とす', () async {
      adapter.enqueue(
        429,
        headers: {
          'x-ratelimit-reset': [resetIn(const Duration(seconds: -10))],
        },
      );
      adapter.enqueue(200);

      final stopwatch = Stopwatch()..start();
      await dio.get('/test');
      stopwatch.stop();

      // jitter 0 の基本遅延 1 秒。
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
      expect(stopwatch.elapsedMilliseconds, lessThan(3000));
      expect(adapter.callCount, 2);
    });

    // ⚠ 壊れた値で例外にしない・待ちもしない。GitHub 風の epoch 秒もここに入る
    // （`DateTime.tryParse` が null を返す）。
    test('⚠ 読めない reset はバックオフへ落とす', () async {
      adapter.enqueue(
        429,
        headers: {
          'x-ratelimit-reset': ['1790000000'],
        },
      );
      adapter.enqueue(200);

      final stopwatch = Stopwatch()..start();
      await dio.get('/test');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
      expect(adapter.callCount, 2);
    });

    // ⚠⚠ **共有フィールドの [_resetAt] を使うと、ここが壊れる。**先行する応答が
    // 入れた遠い窓が残っていると、**ヘッダを持たない 429 で関係の無い窓を待つ**
    // （または諦める）ことになる。この応答のヘッダだけを読むことの歯。
    test('⚠⚠ 別の応答が入れた reset を引きずらない', () async {
      // 1 本目: 成功応答が遠い reset を共有フィールドへ入れる。
      adapter.enqueue(
        200,
        headers: {
          // remaining は閾値より上にして、先回りの待機が走らないようにする。
          'x-ratelimit-remaining': ['100'],
          'x-ratelimit-reset': [resetIn(const Duration(minutes: 5))],
        },
      );
      await dio.get('/first');

      // 2 本目: reset ヘッダを持たない 429。バックオフで再試行するはず。
      adapter.enqueue(429);
      adapter.enqueue(200);

      final stopwatch = Stopwatch()..start();
      await dio.get('/second');
      stopwatch.stop();

      expect(adapter.callCount, 3, reason: '⚠ 1 本目の遠い窓を見て諦めてはいけない');
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
    });
  });

  /// #1103: `X-RateLimit-Reset` に epoch 秒を返すサーバーへの備え。
  ///
  /// ⚠⚠ **`DateTime.tryParse('1790000000')` は null を返さない。**compact ISO と
  /// して **西暦 178999 年**に解釈される（2026-10-01 実測）。捨てずに信じると:
  ///
  /// - 先回りの待機が **17 万年待つ＝その要求が永久に返らない**
  /// - 429 の再試行は「窓が遠すぎる」と判断して**常に諦める**
  ///
  /// ⚠ **ガードを外すと下の 1 本目はタイムアウトで落ちる**（即座の失敗ではなく
  /// ハングとして現れる）。それがこの不具合の見え方そのもの。
  group('⚠⚠ epoch 秒の reset を信じない (#1103)', () {
    test('⚠⚠ 先回りの待機が止まらない', () async {
      adapter.enqueue(
        200,
        headers: {
          // 閾値以下 ＝ 先回りの待機が走る条件。
          'x-ratelimit-remaining': ['1'],
          'x-ratelimit-reset': ['1790000000'],
        },
      );
      await dio.get('/first');

      adapter.enqueue(200);
      final stopwatch = Stopwatch()..start();
      await dio.get('/second');
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(500),
        reason: '⚠⚠ 捨てていないと 17 万年待つ（テストはタイムアウトで落ちる）',
      );
    });

    test('⚠ 429 の再試行でも諦めずバックオフへ落とす', () async {
      adapter.enqueue(
        429,
        headers: {
          'x-ratelimit-reset': ['1790000000'],
        },
      );
      adapter.enqueue(200);

      await dio.get('/test');

      expect(adapter.callCount, 2, reason: '「窓が遠すぎる」と誤判定して諦めない');
    });

    // 対照群。まともな ISO 8601 は捨てない（捨てる側に倒れすぎていないこと）。
    test('まともな reset は捨てない（対照群）', () async {
      adapter.enqueue(
        429,
        headers: {
          'x-ratelimit-reset': [
            DateTime.now()
                .add(const Duration(seconds: 2))
                .toUtc()
                .toIso8601String(),
          ],
        },
      );
      adapter.enqueue(200);

      final stopwatch = Stopwatch()..start();
      await dio.get('/test');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(1500));
    });
  });
}
