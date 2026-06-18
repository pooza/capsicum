import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #729 / mulukhiya #4415: 共有ナウプレの URL→メタ逆 enrich
/// (POST /nowplaying/resolve-url)。レスポンス解釈（ヒット→NowPlayingInfo /
/// {url:null}→null / 非 http→null / 4xx→null）と bearer 送信を検証する。

class _RouteAdapter implements HttpClientAdapter {
  _RouteAdapter({required this.status, required this.body});

  final int status;
  final Object body;
  RequestOptions? captured;
  String? capturedBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('/nowplaying/resolve-url')) {
      captured = options;
      if (requestStream != null) {
        final chunks = await requestStream.toList();
        capturedBody = utf8.decode(chunks.expand((e) => e).toList());
      }
      return _json(body, status);
    }
    return _json({
      'package': {'version': '5.27.0'},
      'config': {
        'controller': 'mastodon',
        'features': {'nowplaying_url_resolver': true},
      },
    }, 200);
  }

  ResponseBody _json(Object b, int s) => ResponseBody.fromString(
    jsonEncode(b),
    s,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<({MulukhiyaService service, _RouteAdapter adapter})> _build({
  int status = 200,
  required Object body,
}) async {
  final adapter = _RouteAdapter(status: status, body: body);
  final dio = Dio()..httpClientAdapter = adapter;
  final service = await MulukhiyaService.detect(dio, 'h.example');
  return (service: service!, adapter: adapter);
}

void main() {
  group('MulukhiyaService.resolveNowPlayingByUrl (#729)', () {
    test('features.nowplaying_url_resolver を検出する', () async {
      final built = await _build(body: {'url': null});
      expect(built.service.nowplayingUrlResolverEnabled, isTrue);
    });

    test('ヒット時は NowPlayingInfo(title/artist/album/url) を返す + bearer', () async {
      final built = await _build(
        body: {
          'url': 'https://open.spotify.com/track/abc',
          'provider': 'spotify',
          'normalized': {
            'title': 'シュビドゥビ☆スイーツタイム',
            'artist': '宮本佳那子',
            'album': 'スイート☆エチュード',
          },
        },
      );
      final info = await built.service.resolveNowPlayingByUrl(
        accessToken: 'tok123',
        url: 'https://open.spotify.com/track/abc',
      );
      expect(info, isNotNull);
      expect(info!.title, 'シュビドゥビ☆スイーツタイム');
      expect(info.artist, '宮本佳那子');
      expect(info.album, 'スイート☆エチュード');
      expect(info.url, Uri.parse('https://open.spotify.com/track/abc'));
      expect(info.sourceAppName, 'Spotify'); // provider ラベル
      expect(built.adapter.captured?.headers['Authorization'], 'Bearer tok123');
      final sent = jsonDecode(built.adapter.capturedBody!) as Map;
      expect(sent['url'], 'https://open.spotify.com/track/abc');
    });

    test('apple_music provider は Apple Music ラベル', () async {
      final built = await _build(
        body: {
          'url': 'https://music.apple.com/jp/song/1',
          'provider': 'apple_music',
          'normalized': {'title': 'Song'},
        },
      );
      final info = await built.service.resolveNowPlayingByUrl(
        accessToken: 't',
        url: 'https://music.apple.com/jp/song/1',
      );
      expect(info?.sourceAppName, 'Apple Music');
    });

    test('解決不可 (200 + url:null) は null', () async {
      final built = await _build(body: {'url': null});
      final info = await built.service.resolveNowPlayingByUrl(
        accessToken: 't',
        url: 'https://example.com/x',
      );
      expect(info, isNull);
    });

    test('非 http スキームの正規化結果は null に倒す', () async {
      final built = await _build(
        body: {'url': 'spotify:track:abc', 'normalized': {'title': 'X'}},
      );
      final info = await built.service.resolveNowPlayingByUrl(
        accessToken: 't',
        url: 'https://open.spotify.com/track/abc',
      );
      expect(info, isNull);
    });

    test('認証失効 (403) / 未提供 (404) は null に倒す', () async {
      for (final status in [403, 404]) {
        final built = await _build(status: status, body: {'error': 'x'});
        final info = await built.service.resolveNowPlayingByUrl(
          accessToken: 't',
          url: 'https://example.com/x',
        );
        expect(info, isNull, reason: 'status=$status');
      }
    });
  });
}
