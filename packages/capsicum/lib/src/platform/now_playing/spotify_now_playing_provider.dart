import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';

import 'now_playing_provider.dart';

/// モロヘイヤ経由で Spotify の「現在再生中の曲」を取得する [NowPlayingProvider]
/// 実装 (#570)。OS ネイティブ源 (MPRIS / SMTC / Apple Music) と違い OS 非依存で、
/// 全プラットフォームで使える。優先順位は最上位 ([NowPlayingResolver]) —
/// currently_playing が共有 URL を直接返すため、整形も enrich (#669) も不要
/// (info.url が埋まる)。
///
/// 認証はアカウントの SNS access_token を Bearer で渡すだけ。Spotify
/// access_token の refresh はモロヘイヤ側が隠蔽する (design:
/// docs/spotify-nowplaying-design.md)。
class SpotifyNowPlayingProvider implements NowPlayingProvider {
  final MulukhiyaService _mulukhiya;
  final String _accessToken;

  const SpotifyNowPlayingProvider({
    required MulukhiyaService mulukhiya,
    required String accessToken,
  }) : _mulukhiya = mulukhiya,
       _accessToken = accessToken;

  /// サーバーが Spotify を提供 (`spotify_enabled`) かつ当該アカウントが連携済み
  /// (`spotify_linked`) のときのみ true。連携状態は /about 検出時に確定する。
  @override
  bool get isAvailable => _mulukhiya.spotifyEnabled && _mulukhiya.spotifyLinked;

  @override
  Future<NowPlayingInfo?> currentlyPlaying() async {
    try {
      final url = await _mulukhiya.getSpotifyCurrentlyPlaying(_accessToken);
      if (url == null) return null;
      return NowPlayingInfo(sourceAppName: 'Spotify', url: url);
    } on MulukhiyaSpotifyAuthException {
      // 連携失効 (403)。「無音」と誤誘導せず再連携導線を出せるよう、OS 許可不足と
      // 同列の例外で伝播する ([NowPlayingResolver] はこれだけ握り潰さない)。
      throw const NowPlayingPermissionException('spotify_reauth');
    }
  }
}
