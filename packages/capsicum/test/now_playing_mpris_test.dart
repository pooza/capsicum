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

    test('mpris:artUrl は http(s) と file のとき artworkUrl に入る (#1133)', () {
      final http = nowPlayingFromMprisMetadata({
        'xesam:title': 'Song',
        'mpris:artUrl': 'https://i.scdn.co/image/abc',
      }, sourceAppName: 'Spotify');
      expect(http!.artworkUrl, Uri.parse('https://i.scdn.co/image/abc'));

      final file = nowPlayingFromMprisMetadata({
        'xesam:title': 'Song',
        'mpris:artUrl': 'file:///tmp/cover.png',
      }, sourceAppName: 'VLC');
      // ⚠ v1.33 では添付しなかったので捨てていた。添付するようになったので拾う。
      expect(file!.artworkUrl, Uri.parse('file:///tmp/cover.png'));

      final other = nowPlayingFromMprisMetadata({
        'xesam:title': 'Song',
        'mpris:artUrl': 'data:image/png;base64,AAAA',
      }, sourceAppName: 'X');
      expect(other!.artworkUrl, isNull, reason: 'ほかのスキームは拾わない');
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

  // #1388: Linux の Spotify は xesam:artist に 1 人目しか入れない。名義を
  // 引き直すために、曲のページの URL を拾う（投稿の URL にはしない）。
  group('spotifyTrackUrlFromMpris (#1388)', () {
    const id = '2VsQl1PGaT9zcbkn01qYtO'; // 報告で実測された曲の ID
    final expected = Uri.parse('https://open.spotify.com/track/$id');

    test('mpris:trackid のオブジェクトパスの形', () {
      expect(
        spotifyTrackUrlFromMpris({'mpris:trackid': '/com/spotify/track/$id'}),
        expected,
      );
    });

    test('mpris:trackid の URI の形（古い版）', () {
      expect(
        spotifyTrackUrlFromMpris({'mpris:trackid': 'spotify:track:$id'}),
        expected,
      );
    });

    test('xesam:url の open.spotify.com（クエリは落とす）', () {
      expect(
        spotifyTrackUrlFromMpris({
          'xesam:url': 'https://open.spotify.com/track/$id?si=abc',
        }),
        expected,
      );
    });

    test('⚠ 曲以外・Spotify 以外は拾わない', () {
      for (final metadata in <Map<String, Object?>>[
        {'mpris:trackid': '/com/spotify/ad/$id'},
        {'mpris:trackid': 'spotify:local:a:b:c:180'},
        {'mpris:trackid': '/org/mpris/MediaPlayer2/Track/3'},
        {'xesam:url': 'file:///home/user/music/song.flac'},
        {'xesam:url': 'https://open.spotify.com/episode/$id'},
        {'xesam:url': 'https://example.com/track/$id'},
        {'mpris:trackid': '/com/spotify/track/short'},
        <String, Object?>{},
      ]) {
        expect(spotifyTrackUrlFromMpris(metadata), isNull, reason: '$metadata');
      }
    });

    test('nowPlayingFromMprisMetadata が sourceTrackUrl に載せ、url は null のまま', () {
      final info = nowPlayingFromMprisMetadata({
        'xesam:title': 'HEART GOES ON',
        'xesam:artist': ['工藤真由'],
        'mpris:trackid': '/com/spotify/track/$id',
        'xesam:url': 'https://open.spotify.com/track/$id',
      }, sourceAppName: 'Spotify');
      expect(info!.sourceTrackUrl, expected);
      expect(info.url, isNull, reason: '共有 URL は利用者が選んだプロバイダで後段が決める (#681)');
    });
  });
}
