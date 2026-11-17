import 'package:capsicum/src/util/now_playing_formatter.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1388: 源の名義が欠けているとき（Linux の Spotify は `xesam:artist` に
/// 1 人目しか入れない）、曲のページから引き直した名義で置き換える。
void main() {
  const source = NowPlayingInfo(
    sourceAppName: 'Spotify',
    title: 'HEART GOES ON',
    artist: '工藤真由',
    album: 'Album',
  );

  test('引き直した名義（全員）で置き換える', () {
    final merged = nowPlayingWithResolvedArtist(
      source,
      NowPlayingInfo(
        sourceAppName: 'Spotify',
        title: 'HEART GOES ON',
        artist: '工藤真由, 池田彩',
        url: Uri.parse('https://open.spotify.com/track/x'),
      ),
    );
    expect(merged.artist, '工藤真由, 池田彩');
    expect(formatNowPlayingFallback(merged), contains('Artist: 工藤真由, 池田彩'));
  });

  test('⚠ 名義以外は源のまま（曲名・アルバム・共有 URL を持ち込まない）', () {
    final merged = nowPlayingWithResolvedArtist(
      source,
      NowPlayingInfo(
        sourceAppName: 'Spotify',
        title: '別表記',
        artist: 'A, B',
        album: '別のアルバム',
        url: Uri.parse('https://open.spotify.com/track/x'),
      ),
    );
    expect(merged.title, 'HEART GOES ON');
    expect(merged.album, 'Album');
    expect(merged.url, isNull, reason: '共有 URL は利用者が選んだプロバイダで後段が決める (#681)');
  });

  test('引き直せなかった・名義が空なら源のまま', () {
    expect(nowPlayingWithResolvedArtist(source, null), source);
    expect(
      nowPlayingWithResolvedArtist(
        source,
        const NowPlayingInfo(sourceAppName: 'Spotify', artist: '   '),
      ).artist,
      '工藤真由',
    );
  });

  test('sourceTrackUrl は copyWith で引き継がれる（引き直しのあとも残る）', () {
    final withTrack = NowPlayingInfo(
      sourceAppName: 'Spotify',
      title: 't',
      sourceTrackUrl: Uri.parse('https://open.spotify.com/track/x'),
    );
    expect(
      withTrack.copyWith(artist: 'A').sourceTrackUrl,
      withTrack.sourceTrackUrl,
    );
  });
}
