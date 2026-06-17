import 'package:capsicum/src/util/now_playing_formatter.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #466 capsicum 側整形。複数行ラベル形式（Title/Album/Artist 行 + URL 独立行 +
/// 裸の `#nowplaying` 末尾行）を組めること、URL は **#nowplaying と同一行に置かない**
/// ことを確認。
///
/// URL を独立行・タグを裸で末尾にするのは、モロヘイヤの「`#nowplaying` 行の直後の
/// URL を同一行へ引き上げて整形ハンドラを再発火させ、Title/Album/Artist を二重付与
/// する」正規化を踏ませないため（二重化対策）。

void main() {
  group('formatNowPlayingFallback', () {
    test('URL + title/album/artist はラベル行 + URL 独立行 + 裸の末尾タグを組む', () {
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
        'https://music.apple.com/jp/song/1352845804\n'
        '#nowplaying',
      );
    });

    test('URL は #nowplaying と同一行に置かない（モロヘイヤ再発火による二重化防止）', () {
      final info = NowPlayingInfo(
        sourceAppName: 'Apple Music',
        title: 'Song',
        artist: 'Artist',
        url: Uri.parse('https://open.spotify.com/track/xyz'),
      );
      final out = formatNowPlayingFallback(info);
      // タグは裸で最終行。URL がタグと同一行に乗っていない。
      expect(out.split('\n').last, nowPlayingTag);
      expect(out, isNot(contains('$nowPlayingTag http')));
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

    test('URL があれば title/artist が空でも URL 独立行 + 末尾タグで成立', () {
      final info = NowPlayingInfo(
        sourceAppName: 'Spotify',
        url: Uri.parse('https://open.spotify.com/track/xyz'),
      );
      expect(
        formatNowPlayingFallback(info),
        'https://open.spotify.com/track/xyz\n#nowplaying',
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

  group('composeSharedNowPlaying', () {
    // #670: 共有(push)テキストもタグを末尾規律に揃える。
    // #727: 共有は URL しか持たずメタはモロヘイヤ enrich 任せのため、単一 URL は
    // 同一行（発火させる）。アプリ内 formatter と方針が逆である点に注意。

    test('単一 URL はタグと同一行（モロヘイヤ enrich を発火させる）', () {
      expect(
        composeSharedNowPlaying('https://music.apple.com/jp/song/1352845804'),
        '#nowplaying https://music.apple.com/jp/song/1352845804',
      );
    });

    test('プレーンテキストはテキスト先・タグ末尾（行頭に置かない）', () {
      expect(
        composeSharedNowPlaying('シュビドゥビ☆スイーツタイム 宮本佳那子'),
        'シュビドゥビ☆スイーツタイム 宮本佳那子\n#nowplaying',
      );
    });

    test('複数行テキストでもタグは末尾（次行詰めの巻き添えを防ぐ）', () {
      expect(
        composeSharedNowPlaying('Title\nArtist'),
        'Title\nArtist\n#nowplaying',
      );
    });

    test('URL の後にテキストが続く（単一 URL でない）ならテキスト先・タグ末尾', () {
      expect(
        composeSharedNowPlaying('https://example.com/x 再生中'),
        'https://example.com/x 再生中\n#nowplaying',
      );
    });

    test('前後の空白はトリムする', () {
      expect(composeSharedNowPlaying('  Song  '), 'Song\n#nowplaying');
    });

    test('空文字なら裸のタグ', () {
      expect(composeSharedNowPlaying('   '), '#nowplaying');
    });

    test('http/https 以外のスキームは単一 URL 扱いしない', () {
      expect(
        composeSharedNowPlaying('capsicum://share'),
        'capsicum://share\n#nowplaying',
      );
    });
  });
}
