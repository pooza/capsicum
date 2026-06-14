import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #669 / mulukhiya #4382: ナウプレ enrich (POST /nowplaying/resolve) の
/// クライアント実装。レスポンス解釈（ヒット / null / エラー → null）と、
/// 構造化メタデータ・bearer 認証の送信を検証する。

/// パスでルーティングし、/nowplaying/resolve のリクエストを捕捉するアダプタ。
class _RouteAdapter implements HttpClientAdapter {
  _RouteAdapter({required this.resolveStatus, required this.resolveBody});

  final int resolveStatus;
  final Object resolveBody;
  RequestOptions? capturedResolve;
  String? capturedResolveBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/nowplaying/resolve')) {
      capturedResolve = options;
      if (requestStream != null) {
        final chunks = await requestStream.toList();
        capturedResolveBody = utf8.decode(chunks.expand((e) => e).toList());
      }
      return ResponseBody.fromString(
        jsonEncode(resolveBody),
        resolveStatus,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    // /about（detect 用の最小レスポンス）。
    return ResponseBody.fromString(
      jsonEncode({
        'package': {'version': '5.25.0'},
        'config': {
          'controller': 'mastodon',
          'features': {'nowplaying_resolver': true},
        },
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

Future<({MulukhiyaService service, _RouteAdapter adapter})> _build({
  int resolveStatus = 200,
  required Object resolveBody,
}) async {
  final adapter = _RouteAdapter(
    resolveStatus: resolveStatus,
    resolveBody: resolveBody,
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final service = await MulukhiyaService.detect(dio, 'h.example');
  return (service: service!, adapter: adapter);
}

void main() {
  group('MulukhiyaService.resolveNowPlaying (#669)', () {
    test('features.nowplaying_resolver を検出する', () async {
      final built = await _build(resolveBody: {'url': null});
      expect(built.service.nowplayingResolverEnabled, isTrue);
    });

    test('ヒット時は url を Uri で返す', () async {
      final built = await _build(
        resolveBody: {
          'url': 'https://music.apple.com/jp/song/1352845804',
          'provider': 'apple_music',
          'normalized': {'title': 'シュビドゥビ☆スイーツタイム'},
        },
      );
      final url = await built.service.resolveNowPlaying(
        accessToken: 'tok123',
        title: 'シュビドゥビ',
        artist: '宮本佳那子',
        album: 'スイート☆エチュード',
        sourceAppName: 'Apple Music',
      );
      expect(url, Uri.parse('https://music.apple.com/jp/song/1352845804'));
    });

    test('構造化メタデータと bearer を送る', () async {
      final built = await _build(resolveBody: {'url': null});
      await built.service.resolveNowPlaying(
        accessToken: 'tok123',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        sourceAppName: 'Apple Music',
      );
      expect(
        built.adapter.capturedResolve?.headers['Authorization'],
        'Bearer tok123',
      );
      final body =
          jsonDecode(built.adapter.capturedResolveBody!) as Map<String, dynamic>;
      expect(body['title'], 'Song');
      expect(body['artist'], 'Artist');
      expect(body['album'], 'Album');
      expect(body['source_app_name'], 'Apple Music');
    });

    test('任意フィールドが null ならキー自体を送らない', () async {
      final built = await _build(resolveBody: {'url': null});
      await built.service.resolveNowPlaying(accessToken: 't', title: 'Song');
      final body =
          jsonDecode(built.adapter.capturedResolveBody!) as Map<String, dynamic>;
      expect(body.containsKey('title'), isTrue);
      expect(body.containsKey('artist'), isFalse);
      expect(body.containsKey('album'), isFalse);
      expect(body.containsKey('source_app_name'), isFalse);
    });

    test('ヒットなし (200 + url:null) は null', () async {
      final built = await _build(resolveBody: {'url': null});
      final url = await built.service.resolveNowPlaying(
        accessToken: 't',
        title: 'Song',
      );
      expect(url, isNull);
    });

    test('認証失効 (403) は null に倒す', () async {
      final built = await _build(
        resolveStatus: 403,
        resolveBody: {'error': 'Unauthorized'},
      );
      final url = await built.service.resolveNowPlaying(
        accessToken: 't',
        title: 'Song',
      );
      expect(url, isNull);
    });

    test('未提供 (404) は null に倒す', () async {
      final built = await _build(
        resolveStatus: 404,
        resolveBody: {'error': 'Not Found'},
      );
      final url = await built.service.resolveNowPlaying(
        accessToken: 't',
        title: 'Song',
      );
      expect(url, isNull);
    });

    test('バリデーション (422) は null に倒す', () async {
      final built = await _build(
        resolveStatus: 422,
        resolveBody: {
          'errors': {'title': 'required'},
        },
      );
      final url = await built.service.resolveNowPlaying(
        accessToken: 't',
        title: 'Song',
      );
      expect(url, isNull);
    });
  });
}
