import 'package:capsicum/src/util/now_playing_formatter.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #466 capsicum 側フォールバック整形。モロヘイヤ `text_nowplaying_formatter`
/// と揃えた複数行ラベル形式（`#nowplaying` + Title/Album/Artist 行）を組める
/// こと、URL を持つ源は 1 行目に URL を載せることを確認。

void main() {
  group('formatNowPlayingFallback', () {
    test('URL + title/album/artist は URL 行とラベル行を組む', () {
      final info = NowPlayingInfo(
        sourceAppName: 'Apple Music',
        title: 'シュビドゥビ☆スイーツタイム',
        album: 'スイート☆エチュード☆アラモード',
        artist: '宮本佳那子',
        url: Uri.parse('https://music.apple.com/jp/song/1352845804'),
      );
      expect(
        formatNowPlayingFallback(info),
        '#nowplaying https://music.apple.com/jp/song/1352845804\n'
        'Title: シュビドゥビ☆スイーツタイム\n'
        'Album: スイート☆エチュード☆アラモード\n'
        'Artist: 宮本佳那子',
      );
    });

    test('URL が無い源（SMTC / MPRIS）は Title/Album/Artist 行を組む', () {
      const info = NowPlayingInfo(
        sourceAppName: 'Spotify',
        title: '閃華裂光拳',
        album: 'ダイの大冒険 BEST',
        artist: 'ダイ',
      );
      expect(
        formatNowPlayingFallback(info),
        '#nowplaying\nTitle: 閃華裂光拳\nAlbum: ダイの大冒険 BEST\nArtist: ダイ',
      );
    });

    test('取れたフィールドだけ列挙する（album 欠損）', () {
      const info = NowPlayingInfo(
        sourceAppName: 'Spotify',
        title: 'Song',
        artist: 'Artist',
      );
      expect(
        formatNowPlayingFallback(info),
        '#nowplaying\nTitle: Song\nArtist: Artist',
      );
    });

    test('artist が無ければ Title 行だけ', () {
      const info = NowPlayingInfo(sourceAppName: 'VLC', title: 'Song');
      expect(formatNowPlayingFallback(info), '#nowplaying\nTitle: Song');
    });

    test('title が無ければ Artist 行だけ', () {
      const info = NowPlayingInfo(sourceAppName: 'VLC', artist: 'Artist');
      expect(formatNowPlayingFallback(info), '#nowplaying\nArtist: Artist');
    });

    test('空白のみのフィールドは欠損扱い', () {
      const info = NowPlayingInfo(
        sourceAppName: 'VLC',
        title: '   ',
        artist: '',
      );
      // すべて欠損 → 源アプリ名にフォールバック。
      expect(formatNowPlayingFallback(info), '#nowplaying VLC');
    });

    test('ラベル値の前後空白はトリムする', () {
      const info = NowPlayingInfo(
        sourceAppName: 'VLC',
        title: '  Song  ',
        artist: '  Artist  ',
      );
      expect(
        formatNowPlayingFallback(info),
        '#nowplaying\nTitle: Song\nArtist: Artist',
      );
    });

    test('メタデータ・源アプリ名すべて空なら裸のタグ', () {
      const info = NowPlayingInfo(sourceAppName: '');
      expect(formatNowPlayingFallback(info), '#nowplaying');
    });

    test('URL があれば title/artist が空でも URL 行のみで成立', () {
      final info = NowPlayingInfo(
        sourceAppName: 'Spotify',
        url: Uri.parse('https://open.spotify.com/track/xyz'),
      );
      expect(
        formatNowPlayingFallback(info),
        '#nowplaying https://open.spotify.com/track/xyz',
      );
    });
  });
}
