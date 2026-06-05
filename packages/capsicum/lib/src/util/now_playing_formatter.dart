import 'package:capsicum_core/capsicum_core.dart';

/// 投稿本文に付けるナウプレのタグ。既存の共有（push）動線
/// （compose_screen の `#nowplaying ${sharedText}`）と揃える。
const _nowPlayingTag = '#nowplaying';

/// [NowPlayingInfo] を投稿本文用テキストに整形する **capsicum 側フォールバック**
/// 整形 (#466 / v1.33)。
///
/// 整形は本来 2 段（design §URL を持つ源と持たない源）:
///
/// 1. モロヘイヤ `text_nowplaying_formatter`（mulukhiya #4382）— プリセット
///    サーバーで title/artist/album を渡して整形済みテキストを得る。
/// 2. 本関数 — モロヘイヤ未配備サーバー / オフライン用の最低限フォールバック。
///    これが無いと「モロヘイヤありき」になり、#466 の「未配備でも動く」制約を
///    満たせない。
///
/// 方針（モロヘイヤ `text_nowplaying_formatter` の出力と揃えた複数行形式）:
///
/// ```
/// #nowplaying <URL があれば>
/// Title: <title>
/// Album: <album>
/// Artist: <artist>
/// ```
///
/// - 1 行目は常にタグ。[NowPlayingInfo.url] が非 null（Spotify 等）なら URL を
///   続ける（SNS / モロヘイヤが unfurl する）。
/// - 続けて Title / Album / Artist を**取れたものだけ**ラベル付きで列挙する
///   （MPRIS / SMTC は URL を持たないが title/album/artist を返す）。
/// - メタデータが 1 つも無ければ、URL があればそれだけ、無ければ源アプリ名、
///   それも空なら裸のタグ。
String formatNowPlayingFallback(NowPlayingInfo info) {
  final url = info.url;
  final firstLine = url != null ? '$_nowPlayingTag $url' : _nowPlayingTag;

  final labeled = <String>[
    for (final (label, value) in [
      ('Title', info.title),
      ('Album', info.album),
      ('Artist', info.artist),
    ])
      if (value != null && value.trim().isNotEmpty) '$label: ${value.trim()}',
  ];

  if (labeled.isEmpty) {
    // title/album/artist がすべて欠損。URL があればそれだけで成立する。
    if (url != null) return firstLine;
    // それも無ければ源アプリ名を出す（"VLC で再生中" 相当の情報をゼロにしない
    // ため）。源アプリ名も空なら裸のタグ。
    final source = info.sourceAppName.trim();
    return source.isEmpty ? _nowPlayingTag : '$_nowPlayingTag $source';
  }

  return [firstLine, ...labeled].join('\n');
}
