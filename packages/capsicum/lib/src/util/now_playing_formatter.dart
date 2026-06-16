import 'package:capsicum_core/capsicum_core.dart';

/// 投稿本文に付けるナウプレのタグ。共有（push）動線（compose_screen の
/// 共有テキスト挿入）もこの定数を参照し、リテラルの二重管理を避ける。
const nowPlayingTag = '#nowplaying';

/// [NowPlayingInfo] を投稿本文用テキストに整形する (#466 / v1.33)。
///
/// テキスト整形は **capsicum 側で完結**させる方針（design §責務分担）。曲メタの
/// 取得はサーバー（モロヘイヤ enrich `/nowplaying/resolve`）に頼ることがあるが、
/// **本文の文字列整形はクライアントが正**。モロヘイヤ側の旧ナウプレ整形ハンドラ
/// （投稿本文の `#nowplaying <url>` 行を見て Title/Album/Artist を書き足す）には
/// 依存しない。自前メタと旧ハンドラのメタが二重化したため、URL をタグと同一行へ
/// 置かない形に統一した（#727 二重化対策）。
///
/// 方針（複数行ラベル形式・URL は独立行・タグは裸で末尾）:
///
/// ```
/// Title: <title>
/// Album: <album>
/// Artist: <artist>
/// <URL があれば独立行>
/// #nowplaying
/// ```
///
/// - Title / Album / Artist を**取れたものだけ**ラベル付きで列挙する
///   （MPRIS / SMTC / Apple Music は title/album/artist を返す）。
/// - [NowPlayingInfo.url] が非 null（enrich 補完 / Spotify 等）なら **URL を独立行**
///   で置く（SNS が unfurl する）。
/// - **`#nowplaying` は裸で末尾**に固定し、URL や本文を同一行に続けない。
///
///   モロヘイヤは「`#nowplaying` 行の直後（改行を跨いでも）にある URL を同一行へ
///   引き上げ、ナウプレ整形ハンドラを発火させて Title/Album/Artist を書き足す」
///   正規化を持つ（handler.rb の `[[:space:]]` 引き上げ）。capsicum が既にメタを
///   自前で出しているとこれが二重化する。URL をタグの**前**の独立行に置き、タグを
///   末尾・後続なしにすれば引き上げ対象が無く発火しない。
///   **URL を `#nowplaying` と同一行／直後に置かないこと。**
/// - メタも URL も無ければ源アプリ名（"VLC で再生中" 相当をゼロにしない）、それも
///   空なら裸のタグ。
String formatNowPlayingFallback(NowPlayingInfo info) {
  final url = info.url;

  final labeled = <String>[
    for (final (label, value) in [
      ('Title', info.title),
      ('Album', info.album),
      ('Artist', info.artist),
    ])
      if (_oneLine(value).isNotEmpty) '$label: ${_oneLine(value)}',
  ];

  if (labeled.isEmpty && url == null) {
    // title/album/artist も URL も無い。源アプリ名を出す。源アプリ名も空なら裸のタグ。
    final source = _oneLine(info.sourceAppName);
    return source.isEmpty ? nowPlayingTag : '$nowPlayingTag $source';
  }

  // URL は #nowplaying の前の独立行、タグは裸で末尾（上記の二重化対策）。
  return [
    ...labeled,
    if (url != null) url.toString(),
    nowPlayingTag,
  ].join('\n');
}

/// 共有 (push) 動線の**不透明な共有テキスト**に `#nowplaying` タグを付ける (#670)。
///
/// 共有はテキスト / URL を不透明に受け取るだけで曲メタ（Title/Album/Artist）を
/// 持たないため、構造化整形はしない。共有テキストを先に置き、`#nowplaying` を
/// **裸で末尾**に付けるだけにする（[formatNowPlayingFallback] と同じ規律に統一）。
///
/// 単一 URL でも**タグと同一行に置かない**（#727）。`#nowplaying <url>` 同一行は
/// 本体整形とフォーマットがずれるうえ、モロヘイヤの旧ナウプレ整形ハンドラを発火
/// させる構造になる。URL を前・タグを末尾にすれば発火せず、unfurl も従来どおり効く。
/// URL→メタの自前補完（resolve-by-URL）は将来の上積み。
String composeSharedNowPlaying(String sharedText) {
  final trimmed = sharedText.trim();
  if (trimmed.isEmpty) return nowPlayingTag;
  return '$trimmed\n$nowPlayingTag';
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
