import 'package:capsicum/src/platform/now_playing/smtc_now_playing_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// #484 SMTC メソッドチャンネルの戻り値 → NowPlayingInfo 変換。ネイティブ
/// （C++/WinRT）I/O から切り出した純関数を検証する（実バスでの動作確認は
/// Windows 実機で行う）。

void main() {
  group('nowPlayingFromSmtcMetadata', () {
    test('title / artist / albumTitle を組む。SMTC は URL を持たない', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': 'Song',
        'artist': 'Artist',
        'albumTitle': 'Album',
        'sourceAppId': 'Spotify.exe',
        'status': 4, // Playing
      });
      expect(info, isNotNull);
      expect(info!.title, 'Song');
      expect(info.artist, 'Artist');
      expect(info.album, 'Album');
      expect(info.sourceAppName, 'Spotify'); // .exe を落とす
      expect(info.url, isNull);
    });

    test('artist が無く title だけでも成立する', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': 'Song',
        'artist': '',
        'sourceAppId': 'vlc.exe',
      });
      expect(info, isNotNull);
      expect(info!.artist, isNull);
      expect(info.title, 'Song');
    });

    test('title も artist も無ければ null', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': '   ',
        'artist': '',
        'albumTitle': 'Album only',
      });
      expect(info, isNull);
    });

    test('前後の空白はトリムする', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': '  Song  ',
        'artist': '  Artist  ',
      });
      expect(info!.title, 'Song');
      expect(info.artist, 'Artist');
    });

    test('sourceAppId が AUMID 等で .exe でなければそのまま使う', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': 'Song',
        'sourceAppId': 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify',
      });
      expect(
        info!.sourceAppName,
        'SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify',
      );
    });

    test('sourceAppId 欠落時は空の sourceAppName', () {
      final info = nowPlayingFromSmtcMetadata({'title': 'Song'});
      expect(info!.sourceAppName, '');
    });

    test('想定外の型（数値）の title は無視', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': 123,
        'artist': 'Artist',
      });
      expect(info!.title, isNull);
      expect(info.artist, 'Artist');
    });
  });
}
