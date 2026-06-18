import 'dart:convert';

import 'package:capsicum/src/platform/now_playing/now_playing_provider.dart';
import 'package:capsicum/src/platform/now_playing/spotify_now_playing_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #570 Spotify ナウプレ源。mulukhiya 経由の currently_playing を
/// NowPlayingInfo に変換し、連携状態で isAvailable を出し分け、403 失効は
/// 「無音」でなく [NowPlayingPermissionException]('spotify_reauth') に変換する。

class _SpotifyAdapter implements HttpClientAdapter {
  _SpotifyAdapter({
    this.enabled = true,
    this.linked = true,
    this.status = 200,
    this.body = const {'url': null},
  });

  final bool enabled;
  final bool linked;
  final int status;
  final Object body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('/spotify/currently_playing')) {
      return _json(body, status);
    }
    return _json({
      'package': {'version': '5.27.0'},
      'config': {
        'controller': 'mastodon',
        'features': {'spotify_enabled': enabled, 'spotify_linked': linked},
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

Future<MulukhiyaService> _service(_SpotifyAdapter adapter) async {
  final dio = Dio()..httpClientAdapter = adapter;
  return (await MulukhiyaService.detect(dio, 'h.example'))!;
}

void main() {
  group('SpotifyNowPlayingProvider', () {
    test('連携済みかつ有効なら isAvailable=true', () async {
      final provider = SpotifyNowPlayingProvider(
        mulukhiya: await _service(_SpotifyAdapter()),
        accessToken: 't',
      );
      expect(provider.isAvailable, isTrue);
    });

    test('未連携なら isAvailable=false', () async {
      final provider = SpotifyNowPlayingProvider(
        mulukhiya: await _service(_SpotifyAdapter(linked: false)),
        accessToken: 't',
      );
      expect(provider.isAvailable, isFalse);
    });

    test('サーバー無効なら isAvailable=false', () async {
      final provider = SpotifyNowPlayingProvider(
        mulukhiya: await _service(_SpotifyAdapter(enabled: false)),
        accessToken: 't',
      );
      expect(provider.isAvailable, isFalse);
    });

    test('再生中は URL を持つ NowPlayingInfo を返す', () async {
      final provider = SpotifyNowPlayingProvider(
        mulukhiya: await _service(
          _SpotifyAdapter(
            body: {'url': 'https://open.spotify.com/track/abc'},
          ),
        ),
        accessToken: 't',
      );
      final info = await provider.currentlyPlaying();
      expect(info?.sourceAppName, 'Spotify');
      expect(info?.url, Uri.parse('https://open.spotify.com/track/abc'));
    });

    test('未再生は null', () async {
      final provider = SpotifyNowPlayingProvider(
        mulukhiya: await _service(_SpotifyAdapter(body: {'url': null})),
        accessToken: 't',
      );
      expect(await provider.currentlyPlaying(), isNull);
    });

    test('連携失効 (403) は spotify_reauth の許可例外に変換する', () async {
      final provider = SpotifyNowPlayingProvider(
        mulukhiya: await _service(
          _SpotifyAdapter(status: 403, body: {'error': 'auth required'}),
        ),
        accessToken: 't',
      );
      await expectLater(
        provider.currentlyPlaying(),
        throwsA(
          isA<NowPlayingPermissionException>().having(
            (e) => e.reason,
            'reason',
            'spotify_reauth',
          ),
        ),
      );
    });
  });
}
