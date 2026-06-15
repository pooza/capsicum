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
    },
  );
}
