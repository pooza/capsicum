import 'package:capsicum/src/platform/now_playing/mpris_now_playing_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// #466 MPRIS metadata パース。D-Bus I/O から切り出した純関数を検証する
/// （実バスでの動作確認は Linux 実機で行う）。入力は
/// `entry.value.asVariant().toNative()` 相当のネイティブ値マップ。

void main() {
  group('nowPlayingFromMprisMetadata', () {
    test('title / artist(配列) / album を組む。MPRIS は URL を持たない', () {
      final info = nowPlayingFromMprisMetadata({
        'xesam:title': 'Song',
        'xesam:artist': ['Artist A', 'Artist B'],
        'xesam:album': 'Album',
        'xesam:url': 'file:///home/user/music/song.flac',
      }, sourceAppName: 'VLC media player');

      expect(info, isNotNull);
      expect(info!.title, 'Song');
      expect(info.artist, 'Artist A, Artist B'); // 配列は ", " 連結
      expect(info.album, 'Album');
      expect(info.sourceAppName, 'VLC media player');
      // file:// の xesam:url は拾わない（設計どおり MPRIS は文字情報源）。
      expect(info.url, isNull);
    });

    test('xesam:artist が遅延 Iterable（dbus の MappedListIterable 相当）でも受ける', () {
      // dbus パッケージの DBusArray.toNative() は List ではなく遅延 Iterable
      // （MappedListIterable）を返す。.map() で List でない Iterable を作って
      // 実機の型を再現する（Linux 実機検証 2026-06-05 の回帰防止）。
      final lazyArtists = ['Kanako Miyamoto'].map((s) => s);
      expect(lazyArtists, isNot(isA<List<dynamic>>()));
      final info = nowPlayingFromMprisMetadata({
        'xesam:title': 'True Ambition',
        'xesam:artist': lazyArtists,
      }, sourceAppName: 'Spotify');
      expect(info!.artist, 'Kanako Miyamoto');
    });

    test('xesam:artist が単一文字列（非準拠プレイヤー）でも受ける', () {
      final info = nowPlayingFromMprisMetadata({
        'xesam:title': 'Song',
        'xesam:artist': 'Solo Artist',
      }, sourceAppName: 'Rhythmbox');
      expect(info!.artist, 'Solo Artist');
    });

    test('artist 配列の空要素・空白はトリムして除く', () {
      final info = nowPlayingFromMprisMetadata({
        'xesam:title': 'Song',
        'xesam:artist': ['  A  ', '', '   ', 'B'],
      }, sourceAppName: 'x');
      expect(info!.artist, 'A, B');
    });

    test('title が無く artist だけでも成立する', () {
      final info = nowPlayingFromMprisMetadata({
        'xesam:artist': ['Artist'],
      }, sourceAppName: 'x');
      expect(info, isNotNull);
      expect(info!.title, isNull);
      expect(info.artist, 'Artist');
    });

    test('title も artist も無ければ null（ナウプレにならない）', () {
      final info = nowPlayingFromMprisMetadata({
        'xesam:album': 'Album only',
        'mpris:length': 12345,
      }, sourceAppName: 'x');
      expect(info, isNull);
    });

    test('空白のみの title / 空配列の artist は欠損扱い', () {
      final info = nowPlayingFromMprisMetadata({
        'xesam:title': '   ',
        'xesam:artist': <String>[],
      }, sourceAppName: 'x');
      expect(info, isNull);
    });

    test('mpris:artUrl は http(s) のときだけ artworkUrl に入る', () {
      final http = nowPlayingFromMprisMetadata({
        'xesam:title': 'Song',
        'mpris:artUrl': 'https://i.scdn.co/image/abc',
      }, sourceAppName: 'Spotify');
      expect(http!.artworkUrl, Uri.parse('https://i.scdn.co/image/abc'));

      final file = nowPlayingFromMprisMetadata({
        'xesam:title': 'Song',
        'mpris:artUrl': 'file:///tmp/cover.png',
      }, sourceAppName: 'VLC');
      expect(file!.artworkUrl, isNull); // file:// は拾わない
    });

    test('想定外の型（数値等）の title は無視して null 扱い', () {
      final info = nowPlayingFromMprisMetadata({
        'xesam:title': 42,
        'xesam:artist': ['Artist'],
      }, sourceAppName: 'x');
      expect(info!.title, isNull);
      expect(info.artist, 'Artist');
    });
  });
}
