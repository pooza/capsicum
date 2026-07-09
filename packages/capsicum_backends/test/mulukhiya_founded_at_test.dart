import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #818 / mulukhiya #4434: `/about` の `config.founded_at`（正式オープン日）と
/// `config.preopened_at`（プレ公開日）のパースを検証する。値は ISO 8601 date
/// (`YYYY-MM-DD`) で、ローカル日付として year/month/day がズレずに読めること、
/// 未設定・空・不正値は null に倒れることを確認する。
class _AboutAdapter implements HttpClientAdapter {
  _AboutAdapter(this.config);

  final Map<String, dynamic> config;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({
        'package': {'version': '5.28.1'},
        'config': {'controller': 'mastodon', ...config},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<MulukhiyaService> _detect(Map<String, dynamic> config) async {
  final dio = Dio()..httpClientAdapter = _AboutAdapter(config);
  final service = await MulukhiyaService.detect(dio, 'h.example');
  return service!;
}

void main() {
  group('MulukhiyaService founded_at / preopened_at (#818)', () {
    test('両方設定済み: 沿革 2 日付を local date でパースする', () async {
      final service = await _detect({
        'founded_at': '2021-04-01',
        'preopened_at': '2021-03-14',
      });
      expect(service.foundedAt, DateTime(2021, 4, 1));
      expect(service.preopenedAt, DateTime(2021, 3, 14));
      // preopened <= founded の沿革関係。
      expect(service.preopenedAt!.isBefore(service.foundedAt!), isTrue);
    });

    test('preopened 未設定: 設立のみ非 null（プレ公開は fallback しない）', () async {
      final service = await _detect({'founded_at': '2017-04-19'});
      expect(service.foundedAt, DateTime(2017, 4, 19));
      expect(service.preopenedAt, isNull);
    });

    test('founded 未設定（DB 未接続相当）: 両方 null', () async {
      final service = await _detect(const {});
      expect(service.foundedAt, isNull);
      expect(service.preopenedAt, isNull);
    });

    test('null / 空文字 / 不正値は null に倒す', () async {
      final service = await _detect({'founded_at': null, 'preopened_at': ''});
      expect(service.foundedAt, isNull);
      expect(service.preopenedAt, isNull);

      final bad = await _detect({'founded_at': 'not-a-date'});
      expect(bad.foundedAt, isNull);
    });
  });
}
