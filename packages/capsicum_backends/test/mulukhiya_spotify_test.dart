import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #570 / mulukhiya #4337: Spotify user OAuth + currently-playing クライアント
/// 実装。features 検出 (spotify_enabled / spotify_linked)、各エンドポイントの
/// リクエスト組み立て (bearer / body)、currently_playing のレスポンス解釈
/// (URL / null / 非 http / 403→例外) を検証する。

class _RouteAdapter implements HttpClientAdapter {
  _RouteAdapter({
    this.spotifyEnabled = true,
    this.spotifyLinked = true,
    this.currentlyPlayingStatus = 200,
    this.currentlyPlayingBody = const {'url': null},
  });

  final bool spotifyEnabled;
  final bool spotifyLinked;
  final int currentlyPlayingStatus;
  final Object currentlyPlayingBody;

  RequestOptions? capturedAuth;
  String? capturedAuthBody;
  RequestOptions? capturedUnlink;
  RequestOptions? capturedCurrentlyPlaying;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;

    if (path.endsWith('/spotify/oauth_uri')) {
      return _json({
        'oauth_uri': 'https://accounts.spotify.com/authorize?client_id=abc',
      }, 200);
    }
    if (path.endsWith('/spotify/auth') && options.method == 'POST') {
      capturedAuth = options;
      if (requestStream != null) {
        final chunks = await requestStream.toList();
        capturedAuthBody = utf8.decode(chunks.expand((e) => e).toList());
      }
      return _json({'config': {}}, 200);
    }
    if (path.endsWith('/spotify/auth') && options.method == 'DELETE') {
      capturedUnlink = options;
      return _json({'config': {}}, 200);
    }
    if (path.endsWith('/spotify/currently_playing')) {
      capturedCurrentlyPlaying = options;
      return _json(currentlyPlayingBody, currentlyPlayingStatus);
    }
    // /about（detect 用の最小レスポンス）。
    return _json({
      'package': {'version': '5.27.0'},
      'config': {
        'controller': 'mastodon',
        'features': {
          'spotify_enabled': spotifyEnabled,
          'spotify_linked': spotifyLinked,
        },
      },
    }, 200);
  }

  ResponseBody _json(Object body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<({MulukhiyaService service, _RouteAdapter adapter})> _build({
  bool spotifyEnabled = true,
  bool spotifyLinked = true,
  int currentlyPlayingStatus = 200,
  Object currentlyPlayingBody = const {'url': null},
}) async {
  final adapter = _RouteAdapter(
    spotifyEnabled: spotifyEnabled,
    spotifyLinked: spotifyLinked,
    currentlyPlayingStatus: currentlyPlayingStatus,
    currentlyPlayingBody: currentlyPlayingBody,
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final service = await MulukhiyaService.detect(dio, 'h.example');
  return (service: service!, adapter: adapter);
}

void main() {
  group('MulukhiyaService Spotify (#570)', () {
    test('features.spotify_enabled / spotify_linked を検出する', () async {
      final built = await _build();
      expect(built.service.spotifyEnabled, isTrue);
      expect(built.service.spotifyLinked, isTrue);
    });

    test('フラグ未提供は false に倒す', () async {
      // features を空にした /about を返すアダプタ（旧モロヘイヤ相当）。
      final dio = Dio()..httpClientAdapter = _MinimalAboutAdapter();
      final service = await MulukhiyaService.detect(dio, 'h.example');
      expect(service!.spotifyEnabled, isFalse);
      expect(service.spotifyLinked, isFalse);
    });

    test('getSpotifyOAuthUri は oauth_uri を返す', () async {
      final built = await _build();
      final uri = await built.service.getSpotifyOAuthUri();
      expect(uri, 'https://accounts.spotify.com/authorize?client_id=abc');
    });

    test('authenticateSpotify は code のみ body + bearer を送る', () async {
      final built = await _build();
      await built.service.authenticateSpotify(
        snsToken: 'tok123',
        code: 'auth-code',
      );
      expect(
        built.adapter.capturedAuth?.headers['Authorization'],
        'Bearer tok123',
      );
      final body =
          jsonDecode(built.adapter.capturedAuthBody!) as Map<String, dynamic>;
      expect(body['code'], 'auth-code');
      expect(body.containsKey('token'), isFalse);
    });

    test('unlinkSpotify は DELETE + bearer を送る', () async {
      final built = await _build();
      await built.service.unlinkSpotify('tok123');
      expect(built.adapter.capturedUnlink?.method, 'DELETE');
      expect(
        built.adapter.capturedUnlink?.headers['Authorization'],
        'Bearer tok123',
      );
    });

    test('currently_playing: 再生中は url を Uri で返す + bearer', () async {
      final built = await _build(
        currentlyPlayingBody: {
          'url': 'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC',
        },
      );
      final url = await built.service.getSpotifyCurrentlyPlaying('tok123');
      expect(
        url,
        Uri.parse('https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC'),
      );
      expect(
        built.adapter.capturedCurrentlyPlaying?.headers['Authorization'],
        'Bearer tok123',
      );
    });

    test('currently_playing: 未再生 (url:null) は null', () async {
      final built = await _build(currentlyPlayingBody: {'url': null});
      expect(await built.service.getSpotifyCurrentlyPlaying('t'), isNull);
    });

    test('currently_playing: 非 http スキームは null に倒す', () async {
      final built = await _build(
        currentlyPlayingBody: {'url': 'spotify:track:abc'},
      );
      expect(await built.service.getSpotifyCurrentlyPlaying('t'), isNull);
    });

    test('currently_playing: 連携失効 (403) は例外を投げる', () async {
      final built = await _build(
        currentlyPlayingStatus: 403,
        currentlyPlayingBody: {'error': 'Spotify authentication required'},
      );
      expect(
        () => built.service.getSpotifyCurrentlyPlaying('t'),
        throwsA(isA<MulukhiyaSpotifyAuthException>()),
      );
    });
  });
}

/// features を持たない /about を返す最小アダプタ（フォールバック検証用）。
class _MinimalAboutAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({
        'package': {'version': '5.20.0'},
        'config': {'controller': 'mastodon', 'features': {}},
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
