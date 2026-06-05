import 'package:capsicum_core/capsicum_core.dart';

/// 投稿本文に付けるナウプレのタグ。共有（push）動線（compose_screen の
/// 共有テキスト挿入）もこの定数を参照し、リテラルの二重管理を避ける。
const nowPlayingTag = '#nowplaying';

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
/// Title: <title>
/// Album: <album>
/// Artist: <artist>
/// #nowplaying <URL があれば>
/// ```
///
/// - Title / Album / Artist を**取れたものだけ**ラベル付きで列挙する
///   （MPRIS / SMTC は URL を持たないが title/album/artist を返す）。
/// - **タグ行は末尾に置く**。[NowPlayingInfo.url] が非 null（Spotify 等）なら
///   URL を続ける（SNS / モロヘイヤが unfurl する）。
///
///   タグを先頭でなく**末尾**にするのは **モロヘイヤの正規化対策**（#466）。
///   モロヘイヤは「`#nowplaying` 行に同一行 URL が無いとき次行を詰める」正規化
///   （過去に `#nowplaying` と URL の間へ改行を入れた投稿を整えるために導入）を
///   行う。タグを先頭に置くと、URL の無い MPRIS / SMTC では `#nowplaying` 行に
///   続く `Title:` 行が詰められて結合してしまう。末尾に置けば詰める対象の次行が
///   無く、副作用が出ない。**先頭に戻さないこと。**
/// - メタデータが 1 つも無ければ、URL があればそれだけ、無ければ源アプリ名、
///   それも空なら裸のタグ（いずれも単一行なので正規化の影響を受けない）。
String formatNowPlayingFallback(NowPlayingInfo info) {
  final url = info.url;
  final tagLine = url != null ? '$nowPlayingTag $url' : nowPlayingTag;

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
    if (url != null) return tagLine;
    // それも無ければ源アプリ名を出す（"VLC で再生中" 相当の情報をゼロにしない
    // ため）。源アプリ名も空なら裸のタグ。
    final source = info.sourceAppName.trim();
    return source.isEmpty ? nowPlayingTag : '$nowPlayingTag $source';
  }

  // タグ行は末尾（上記の正規化対策）。
  return [...labeled, tagLine].join('\n');
}
