/// Spotify の曲のページの URL を組む処理を 1 か所に集める (#1403)。
///
/// ⚠ **以前は MPRIS（Linux・#1388）とデスクトップアプリ（macOS・#1276）で別々に
/// 組んでいて、曲 ID の判定がずれていた**（前者は 22 文字固定、後者は
/// `[A-Za-z0-9]+`）。`open.spotify.com` も 4 か所に直書きしていた。
///
/// - ID の形はここの [isSpotifyTrackId] だけが決める
/// - URL はここの [spotifyTrackUrl] だけが組む（クエリは付けない）
library;

/// 曲のページのホスト。
const spotifyWebHost = 'open.spotify.com';

/// Spotify の曲 ID（base62・22 文字）。
final _trackId = RegExp(r'^[0-9A-Za-z]{22}$');

/// `spotify:track:<ID>` の URI、または MPRIS の `mpris:trackid` の
/// `/com/spotify/track/<ID>`（D-Bus のオブジェクトパス）。
final _trackRef = RegExp(r'^(?:/com/spotify/track/|spotify:track:)(.+)$');

/// 曲 ID の形をしているか。
bool isSpotifyTrackId(String id) => _trackId.hasMatch(id);

/// 曲 ID から曲のページの URL を作る。ID の形でなければ null。
Uri? spotifyTrackUrl(String id) =>
    isSpotifyTrackId(id) ? Uri.https(spotifyWebHost, '/track/$id') : null;

/// `spotify:track:<ID>` / `/com/spotify/track/<ID>` から曲のページの URL を
/// 作る。曲以外（`spotify:episode:…`・`/com/spotify/ad/…`・`spotify:local:…`）
/// や形の違うものは null。
Uri? spotifyTrackUrlFromRef(String ref) {
  final match = _trackRef.firstMatch(ref.trim());
  return match == null ? null : spotifyTrackUrl(match.group(1)!);
}

/// `https://open.spotify.com/track/<ID>`（クエリ付きも可）を、クエリを落とした
/// 曲のページの URL にする。曲以外・ほかのホストは null。
Uri? spotifyTrackUrlFromWebUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != spotifyWebHost ||
      uri.pathSegments.length != 2 ||
      uri.pathSegments.first != 'track') {
    return null;
  }
  return spotifyTrackUrl(uri.pathSegments.last);
}
