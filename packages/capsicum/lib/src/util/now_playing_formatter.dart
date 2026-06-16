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
      if (_oneLine(value).isNotEmpty) '$label: ${_oneLine(value)}',
  ];

  if (labeled.isEmpty) {
    // title/album/artist がすべて欠損。URL があればそれだけで成立する。
    if (url != null) return tagLine;
    // それも無ければ源アプリ名を出す（"VLC で再生中" 相当の情報をゼロにしない
    // ため）。源アプリ名も空なら裸のタグ。
    final source = _oneLine(info.sourceAppName);
    return source.isEmpty ? nowPlayingTag : '$nowPlayingTag $source';
  }

  // タグ行は末尾（上記の正規化対策）。
  return [...labeled, tagLine].join('\n');
}

/// 共有 (push) 動線の**不透明な共有テキスト**に `#nowplaying` タグを付ける (#670)。
///
/// [formatNowPlayingFallback] と同じ **「タグは末尾」規律** に揃える。タグを行頭に
/// 置くと、モロヘイヤの「`#nowplaying` 行に同一行 URL が無いと次行を詰める」正規化
/// で、共有テキストが複数行かつ URL 無しのとき次行が詰められて結合してしまう。
/// タグを末尾へ逃がせば詰める対象の次行が無く、副作用が出ない（formatter と同じ
/// 理由。**先頭に戻さないこと**）。
///
/// 共有テキストが単一 URL のときだけ unfurl 用にタグと同一行へ置く
/// （`#nowplaying <url>`）。それ以外はテキストを先に、タグを末尾行に置く。
/// 構造化整形（Title/Album/Artist 行）への完全統一は Share Extension + モロヘイヤ
/// enrich 再設計に依存するため、本関数は **タグ配置だけ** を整える（#670 の制約）。
String composeSharedNowPlaying(String sharedText) {
  final trimmed = sharedText.trim();
  if (trimmed.isEmpty) return nowPlayingTag;
  if (_isSingleUrl(trimmed)) return '$nowPlayingTag $trimmed';
  return '$trimmed\n$nowPlayingTag';
}

/// 共有テキストが**単一 URL**（空白を含まず http(s) スキーム）か。単一 URL なら
/// タグと同一行に置いて unfurl させられる。
bool _isSingleUrl(String text) {
  if (text.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(text);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

/// メタデータ値を **1 行**に正規化する。前後の空白・制御文字を落とし、内部の
/// 改行 / タブ / その他 C0 制御文字 (0x00-0x1f) と DEL (0x7f) の連続は空白 1 つへ
/// 畳む。
///
/// OS / プレイヤー由来のメタデータは信頼できない外部入力であり、title 等に改行が
/// 混入すると本文に余計な行（モロヘイヤ正規化を誘発するタグ行や、なりすまし風の
/// 追記）を注入できてしまう。投稿前にユーザーが目視・編集する設計とはいえ、値が
/// 単一行であることを整形の入口で保証しておく。
String _oneLine(String? value) {
  if (value == null) return '';
  final buffer = StringBuffer();
  var pendingSeparator = false;
  for (final rune in value.runes) {
    // 制御文字 (C0: 0x00-0x1f / DEL: 0x7f) と通常の空白 (0x20) を区切りとして畳む。
    final isSeparator = rune <= 0x20 || rune == 0x7f;
    if (isSeparator) {
      pendingSeparator = true;
      continue;
    }
    // 先頭の区切りは捨てる（trim 相当）。語間の区切りだけ空白 1 つに圧縮する。
    if (pendingSeparator && buffer.isNotEmpty) buffer.write(' ');
    pendingSeparator = false;
    buffer.writeCharCode(rune);
  }
  // 末尾に残った区切りは書き出さない（trim 相当）。
  return buffer.toString();
}
