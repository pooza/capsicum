/// 「現在再生中の曲」を表す、取得源非依存のモデル (#466 / v1.33)。
///
/// 取得源は 2 系統ある（design: docs/nowplaying-design.md）:
///
/// - **URL を持つ源**（Spotify など）— [url] にトラック URL が入る。投稿には
///   URL をそのまま載せ、SNS / モロヘイヤ側で unfurl させる。
/// - **文字情報のみの源**（Linux MPRIS / Windows SMTC）— [url] は null で、
///   [title] / [artist] / [album] から本文テキストを整形する必要がある。
///
/// 純 Dart モデルなので capsicum_core に置く（[Channel] / `Post` などと同じ）。
class NowPlayingInfo {
  /// 曲名。源によっては取得できないことがある。
  final String? title;

  /// アーティスト名。
  final String? artist;

  /// アルバム名。
  final String? album;

  /// アートワーク。MPRIS / SMTC は byte stream を返すため、Uri 化できる源
  /// のみ非 null。v1.33 では投稿添付はせず、モデルにフィールドだけ用意する
  /// （添付 UX は将来検討。design §アートワーク）。
  final Uri? artworkUrl;

  /// 取得元アプリ名（"Spotify" / "VLC" / "Rhythmbox" 等）。表示・整形に使う。
  final String sourceAppName;

  /// トラック URL を持つ源（Spotify 等）のみ非 null。null の場合は文字情報
  /// からの整形パスへ回す（design §URL を持つ源と持たない源）。
  final Uri? url;

  const NowPlayingInfo({
    required this.sourceAppName,
    this.title,
    this.artist,
    this.album,
    this.artworkUrl,
    this.url,
  });

  @override
  bool operator ==(Object other) =>
      other is NowPlayingInfo &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artworkUrl == artworkUrl &&
      other.sourceAppName == sourceAppName &&
      other.url == url;

  @override
  int get hashCode =>
      Object.hash(title, artist, album, artworkUrl, sourceAppName, url);

  @override
  String toString() =>
      'NowPlayingInfo(source: $sourceAppName, title: $title, '
      'artist: $artist, url: $url)';
}
