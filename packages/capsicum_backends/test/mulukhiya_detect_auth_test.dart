import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// リクエストを捕捉しつつ固定レスポンスを返す HttpClientAdapter。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.body);

  final Object body;
  RequestOptions? captured;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _about({Object? annictLinked = true}) => {
  'package': {'version': '5.24.0'},
  'config': {
    'controller': 'mastodon',
    'features': {'annict': true, 'annict_linked': ?annictLinked},
  },
};

void main() {
  group('MulukhiyaService.detect 認証付き /about (#611)', () {
    test('token を渡すと Authorization: Bearer を送る', () async {
      final adapter = _CapturingAdapter(_about());
      final dio = Dio()..httpClientAdapter = adapter;

      await MulukhiyaService.detect(dio, 'h.example', token: 'tok123');

      expect(adapter.captured?.headers['Authorization'], 'Bearer tok123');
    });

    test('token 未指定なら Authorization を送らない', () async {
      final adapter = _CapturingAdapter(_about());
      final dio = Dio()..httpClientAdapter = adapter;

      await MulukhiyaService.detect(dio, 'h.example');

      expect(adapter.captured?.headers.containsKey('Authorization'), isFalse);
    });

    test('annict_linked=true を連携済みとして読む', () async {
      final dio = Dio()
        ..httpClientAdapter = _CapturingAdapter(_about(annictLinked: true));
      final service = await MulukhiyaService.detect(
        dio,
        'h.example',
        token: 't',
      );
      expect(service?.annictLinked, isTrue);
    });

    test('annict_linked=false を未連携として読む', () async {
      final dio = Dio()
        ..httpClientAdapter = _CapturingAdapter(_about(annictLinked: false));
      final service = await MulukhiyaService.detect(
        dio,
        'h.example',
        token: 't',
      );
      expect(service?.annictLinked, isFalse);
    });

    test('annict_linked 欠落（旧モロヘイヤ）は true にフォールバック', () async {
      // record / review 動線が古いサーバーでも従来どおり直行できること。
      final dio = Dio()
        ..httpClientAdapter = _CapturingAdapter(_about(annictLinked: null));
      final service = await MulukhiyaService.detect(
        dio,
        'h.example',
        token: 't',
      );
      expect(service?.annictLinked, isTrue);
    });
  });
}
