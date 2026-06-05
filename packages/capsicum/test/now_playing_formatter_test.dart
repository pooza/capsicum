import 'package:capsicum/src/util/now_playing_formatter.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #466 capsicum 側フォールバック整形。モロヘイヤ `text_nowplaying_formatter`
/// と揃えた複数行ラベル形式（Title/Album/Artist 行 + 末尾 `#nowplaying` 行）を
/// 組めること、URL を持つ源は末尾タグ行に URL を載せることを確認。
///
/// タグ行が**末尾**なのはモロヘイヤの「`#nowplaying` 行に URL が無いと次行を
/// 詰める」正規化対策（#466）。先頭に置くと `Title:` 行が詰められる。

void main() {
  group('formatNowPlayingFallback', () {
    test('URL + title/album/artist はラベル行 + 末尾の URL 付きタグ行を組む', () {
      final info = NowPlayingInfo(
        sourceAppName: 'Apple Music',
        title: 'シュビドゥビ☆スイーツタイム',
        album: 'スイート☆エチュード☆アラモード',
        artist: '宮本佳那子',
        url: Uri.parse('https://music.apple.com/jp/song/1352845804'),
      );
      expect(
        formatNowPlayingFallback(info),
        'Title: シュビドゥビ☆スイーツタイム\n'
        'Album: スイート☆エチュード☆アラモード\n'
        'Artist: 宮本佳那子\n'
        '#nowplaying https://music.apple.com/jp/song/1352845804',
      );
    });

    test('URL が無い源（SMTC / MPRIS）は Title/Album/Artist 行 + 末尾タグ', () {
      const info = NowPlayingInfo(
        sourceAppName: 'Spotify',
        title: '閃華裂光拳',
        album: 'ダイの大冒険 BEST',
        artist: 'ダイ',
      );
      expect(
        formatNowPlayingFallback(info),
        'Title: 閃華裂光拳\nAlbum: ダイの大冒険 BEST\nArtist: ダイ\n#nowplaying',
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
        'Title: Song\nArtist: Artist\n#nowplaying',
      );
    });

    test('artist が無ければ Title 行だけ + 末尾タグ', () {
      const info = NowPlayingInfo(sourceAppName: 'VLC', title: 'Song');
      expect(formatNowPlayingFallback(info), 'Title: Song\n#nowplaying');
    });

    test('title が無ければ Artist 行だけ + 末尾タグ', () {
      const info = NowPlayingInfo(sourceAppName: 'VLC', artist: 'Artist');
      expect(formatNowPlayingFallback(info), 'Artist: Artist\n#nowplaying');
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
        'Title: Song\nArtist: Artist\n#nowplaying',
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

    test('値に埋め込まれた改行・制御文字は空白へ畳んで行注入を防ぐ', () {
      // 信頼できない OS / プレイヤー由来メタに改行が混ざっても、ラベル行が
      // 分断されたり余計な行（偽の #nowplaying 行等）が本文へ注入されないこと。
      const info = NowPlayingInfo(
        sourceAppName: 'VLC',
        title: 'Song\n#nowplaying https://evil.example',
        artist: 'A\tB',
      );
      expect(
        formatNowPlayingFallback(info),
        'Title: Song #nowplaying https://evil.example\n'
        'Artist: A B\n'
        '#nowplaying',
      );
    });

    test('内部の連続空白・タブは空白 1 つへ圧縮する', () {
      const info = NowPlayingInfo(
        sourceAppName: 'VLC',
        title: 'Multiple   spaces\there',
      );
      expect(
        formatNowPlayingFallback(info),
        'Title: Multiple spaces here\n#nowplaying',
      );
    });
  });
}
