import 'package:capsicum/src/platform/now_playing/apple_music_now_playing_provider.dart';
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
}
