import 'package:capsicum/src/util/now_playing_formatter.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #466 capsicum 側フォールバック整形。モロヘイヤ未配備でも最低限の
/// ナウプレ本文を組めること、URL を持つ源は URL をそのまま載せることを確認。

void main() {
  group('formatNowPlayingFallback', () {
    test('URL を持つ源（Spotify）は URL をそのまま載せる', () {
      final info = NowPlayingInfo(
        sourceAppName: 'Spotify',
        title: 'Song',
        artist: 'Artist',
        url: Uri.parse('https://open.spotify.com/track/abc'),
      );
      expect(
        formatNowPlayingFallback(info),
        '#nowplaying https://open.spotify.com/track/abc',
      );
    });

    test('URL が無い源は title / artist を組む', () {
      const info = NowPlayingInfo(
        sourceAppName: 'VLC',
        title: '閃華裂光拳',
        artist: 'ダイ',
      );
      expect(formatNowPlayingFallback(info), '#nowplaying 閃華裂光拳 / ダイ');
    });

    test('artist が無ければ title だけ', () {
      const info = NowPlayingInfo(sourceAppName: 'VLC', title: 'Song');
      expect(formatNowPlayingFallback(info), '#nowplaying Song');
    });

    test('title が無ければ artist だけ', () {
      const info = NowPlayingInfo(sourceAppName: 'VLC', artist: 'Artist');
      expect(formatNowPlayingFallback(info), '#nowplaying Artist');
    });

    test('空白のみの title / artist は欠損扱い', () {
      const info = NowPlayingInfo(
        sourceAppName: 'VLC',
        title: '   ',
        artist: '',
      );
      // 両方欠損 → 源アプリ名にフォールバック。
      expect(formatNowPlayingFallback(info), '#nowplaying VLC');
    });

    test('title / artist の前後空白はトリムする', () {
      const info = NowPlayingInfo(
        sourceAppName: 'VLC',
        title: '  Song  ',
        artist: '  Artist  ',
      );
      expect(formatNowPlayingFallback(info), '#nowplaying Song / Artist');
    });

    test('title・artist・源アプリ名すべて空なら裸のタグ', () {
      const info = NowPlayingInfo(sourceAppName: '');
      expect(formatNowPlayingFallback(info), '#nowplaying');
    });

    test('URL があれば title/artist が空でも URL を優先', () {
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
