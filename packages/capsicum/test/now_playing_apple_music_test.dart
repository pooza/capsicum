import 'dart:io';

import 'package:capsicum/src/platform/now_playing/apple_music_now_playing_provider.dart';
import 'package:capsicum/src/platform/now_playing/now_playing_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #668 Apple Music メソッドチャンネルの戻り値 → NowPlayingInfo 変換。ネイティブ
/// （iOS MPMusicPlayerController / macOS ScriptingBridge）I/O から切り出した
/// 純関数を検証する（実機での動作確認は内部ベータで行う）。

void main() {
  group('nowPlayingFromAppleMusicMetadata', () {
    test('title / artist / albumTitle を組む。Apple Music は URL を持たない', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'title': 'Song',
        'artist': 'Artist',
        'albumTitle': 'Album',
      });
      expect(info, isNotNull);
      expect(info!.title, 'Song');
      expect(info.artist, 'Artist');
      expect(info.album, 'Album');
      expect(info.url, isNull);
    });

    test('artworkPath（macOS がミュージックから取った絵）は file:// にする (#1273)', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'title': 'Song',
        'artworkPath': '/tmp/nowplaying_native_abc/nowplaying-artwork.jpg',
      });
      expect(
        info!.artworkUrl,
        Uri.file('/tmp/nowplaying_native_abc/nowplaying-artwork.jpg'),
      );
      expect(info.artworkUrl!.scheme, 'file');
    });

    test('artworkPath が無い（iOS・絵の無い曲）ならジャケットは null', () {
      final info = nowPlayingFromAppleMusicMetadata({'title': 'Song'});
      expect(info!.artworkUrl, isNull);
    });

    test('⚠ 絶対パスでない artworkPath / 文字列でない値は捨てる', () {
      for (final value in <Object?>['relative/a.jpg', '', '   ', 42]) {
        final info = nowPlayingFromAppleMusicMetadata({
          'title': 'Song',
          'artworkPath': value,
        });
        expect(info!.artworkUrl, isNull, reason: '$value');
      }
    });

    // #1283: ネイティブがジャケットを書き出さなかった理由。
    test('書き出さなかった理由（artworkSkipped）を読む', () {
      for (final reason in kNowPlayingArtworkSkipReasons) {
        final info = nowPlayingFromAppleMusicMetadata({
          'title': 'Song',
          'artworkSkipped': reason,
        });
        expect(info!.artworkSkipReason, reason);
        expect(info.artworkUrl, isNull);
      }
    });

    test('⚠ 知らない値・文字列でない値は捨てる（breadcrumb に素通ししない）', () {
      for (final value in <Object?>['/Users/someone/secret', '', 42, null]) {
        final info = nowPlayingFromAppleMusicMetadata({
          'title': 'Song',
          'artworkSkipped': value,
        });
        expect(info!.artworkSkipReason, isNull, reason: '$value');
      }
    });

    // ⚠ Swift が返す値と Dart の受け口がずれると、理由は黙って捨てられる
    // （上のテストは Dart 側しか見ていない）。ソースを突き合わせる。
    test('⚠⚠ macOS のネイティブが返す理由は、すべて Dart が受け取る値', () {
      final swift = File(
        'macos/Runner/NowPlayingPlugin.swift',
      ).readAsStringSync();
      final returned = {
        ...RegExp(
          r'\.skipped\("([a-z_]+)"\)',
        ).allMatches(swift).map((m) => m.group(1)!),
        ...RegExp(
          r'map\["artworkSkipped"\] = "([a-z_]+)"',
        ).allMatches(swift).map((m) => m.group(1)!),
      };

      expect(returned, isNotEmpty, reason: '走査が空振りしていない');
      expect(returned, kNowPlayingArtworkSkipReasons);
    });

    test('sourceAppName が無ければ Apple Music を既定にする', () {
      final info = nowPlayingFromAppleMusicMetadata({'title': 'Song'});
      expect(info!.sourceAppName, 'Apple Music');
    });

    test('ネイティブが sourceAppName を返せばそれを使う', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'title': 'Song',
        'sourceAppName': 'ミュージック',
      });
      expect(info!.sourceAppName, 'ミュージック');
    });

    test('artist が無く title だけでも成立する', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'title': 'Song',
        'artist': '',
      });
      expect(info, isNotNull);
      expect(info!.artist, isNull);
      expect(info.title, 'Song');
    });

    test('title も artist も無ければ null', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'title': '   ',
        'artist': '',
        'albumTitle': 'Album only',
      });
      expect(info, isNull);
    });

    test('前後の空白はトリムする', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'title': '  Song  ',
        'artist': '  Artist  ',
      });
      expect(info!.title, 'Song');
      expect(info.artist, 'Artist');
    });

    test('想定外の型（数値）の title は無視', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'title': 123,
        'artist': 'Artist',
      });
      expect(info!.title, isNull);
      expect(info.artist, 'Artist');
    });
  });

  group(
    'AppleMusicNowPlayingProvider.currentlyPlaying — macOS 失敗種別 (#668)',
    () {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('capsicum/now_playing');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      void mockReturn(Object? value) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getNowPlaying');
          return value;
        });
      }

      tearDown(() => messenger.setMockMethodCallHandler(channel, null));

      test('通常マップは NowPlayingInfo に変換される', () async {
        mockReturn({'title': 'Song', 'artist': 'Artist'});
        final info = await const AppleMusicNowPlayingProvider()
            .currentlyPlaying();
        expect(info, isNotNull);
        expect(info!.title, 'Song');
      });

      test('null（曲なし）は null を返す', () async {
        mockReturn(null);
        final info = await const AppleMusicNowPlayingProvider()
            .currentlyPlaying();
        expect(info, isNull);
      });

      test('automation_denied は NowPlayingPermissionException を投げる', () async {
        mockReturn({'__nowPlayingError': 'automation_denied'});
        expect(
          () => const AppleMusicNowPlayingProvider().currentlyPlaying(),
          throwsA(
            isA<NowPlayingPermissionException>().having(
              (e) => e.reason,
              'reason',
              'automation_denied',
            ),
          ),
        );
      });

      test('automation_pending も NowPlayingPermissionException を投げる', () async {
        mockReturn({'__nowPlayingError': 'automation_pending'});
        expect(
          () => const AppleMusicNowPlayingProvider().currentlyPlaying(),
          throwsA(
            isA<NowPlayingPermissionException>().having(
              (e) => e.reason,
              'reason',
              'automation_pending',
            ),
          ),
        );
      });

      test('script_error は投げず null に倒す（観測のみ）', () async {
        mockReturn({'__nowPlayingError': 'script_error', '__code': -42});
        final info = await const AppleMusicNowPlayingProvider()
            .currentlyPlaying();
        expect(info, isNull);
      });

      test('no_track（診断付き）は投げず null に倒す', () async {
        mockReturn({
          '__nowPlayingError': 'no_track',
          '__automationStatus': 0,
          '__scriptItems': 0,
        });
        final info = await const AppleMusicNowPlayingProvider()
            .currentlyPlaying();
        expect(info, isNull);
      });

      test('診断キー付きの実トラックは NowPlayingInfo になる', () async {
        mockReturn({'title': 'Song', 'artist': 'A', '__automationStatus': 0});
        final info = await const AppleMusicNowPlayingProvider()
            .currentlyPlaying();
        expect(info?.title, 'Song');
      });
    },
  );

  // #1276: macOS の Spotify のデスクトップアプリ。AppleScript はアートワークを
  // https の URL、共有を `spotify:track:<id>` で返す（2026-10-15 実測）。
  group('Spotify のデスクトップアプリ (#1276)', () {
    test('アートワークの URL・共有 URL・出どころを読む', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'sourceAppName': 'Spotify',
        'title': 'わんだふるぷりきゅあ！evolution!!',
        'artist': '吉武千颯',
        'artworkUrl': 'https://i.scdn.co/image/ab67616d0000b273b99b',
        'shareUri': 'spotify:track:4djHqqL4yQbXxDfPjMBWku',
      });
      expect(info!.sourceAppName, 'Spotify');
      expect(
        info.artworkUrl,
        Uri.parse('https://i.scdn.co/image/ab67616d0000b273b99b'),
      );
      expect(
        info.url,
        Uri.parse('https://open.spotify.com/track/4djHqqL4yQbXxDfPjMBWku'),
        reason: 'spotify: の URI のままでは本文の URL 行に使えない',
      );
    });

    test('⚠ https でないアートワークの URL は捨てる', () {
      for (final value in [
        'http://i.scdn.co/image/x',
        'file:///etc/passwd',
        'not a url',
        42,
      ]) {
        final info = nowPlayingFromAppleMusicMetadata({
          'title': 'Song',
          'artworkUrl': value,
        });
        expect(info!.artworkUrl, isNull, reason: '$value');
      }
    });

    test('⚠ 書き出したファイル（ミュージック）があれば、そちらを採る', () {
      final info = nowPlayingFromAppleMusicMetadata({
        'title': 'Song',
        'artworkPath': '/tmp/nowplaying_native_abc/nowplaying-artwork.jpg',
        'artworkUrl': 'https://i.scdn.co/image/x',
      });
      expect(info!.artworkUrl!.scheme, 'file');
    });

    test('spotifyShareUrl は曲の URI だけを通す', () {
      expect(
        spotifyShareUrl('spotify:track:abc123'),
        Uri.parse('https://open.spotify.com/track/abc123'),
      );
      expect(spotifyShareUrl('spotify:episode:abc123'), isNull);
      expect(spotifyShareUrl('spotify:track:abc/../x'), isNull);
      expect(spotifyShareUrl('https://open.spotify.com/track/abc'), isNull);
      expect(spotifyShareUrl(null), isNull);
    });

    group('プロバイダ', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('capsicum/now_playing');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      tearDown(() => messenger.setMockMethodCallHandler(channel, null));

      test('⚠ 設定の優先サービスをネイティブへ渡す（両方が同じ状態のときの選び方）', () async {
        final received = <Object?>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          received.add(call.arguments);
          return {'title': 'Song'};
        });
        await AppleMusicNowPlayingProvider(
          preferSpotify: () => true,
        ).currentlyPlaying();
        await const AppleMusicNowPlayingProvider().currentlyPlaying();
        expect(received, [
          {'prefer': 'spotify'},
          {'prefer': 'appleMusic'},
        ]);
      });

      test('Spotify の許可の失敗は、アプリ名つきで投げる', () async {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => {
            '__nowPlayingError': 'automation_pending',
            '__app': 'spotify',
          },
        );
        expect(
          () => const AppleMusicNowPlayingProvider().currentlyPlaying(),
          throwsA(
            isA<NowPlayingPermissionException>().having(
              (e) => e.appName,
              'appName',
              'Spotify',
            ),
          ),
        );
      });

      test('ミュージックの許可の失敗は、アプリ名を持たない（従来の文面）', () async {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => {
            '__nowPlayingError': 'automation_denied',
            '__app': 'music',
          },
        );
        expect(
          () => const AppleMusicNowPlayingProvider().currentlyPlaying(),
          throwsA(
            isA<NowPlayingPermissionException>().having(
              (e) => e.appName,
              'appName',
              isNull,
            ),
          ),
        );
      });
    });
  });
}
