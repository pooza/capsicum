import '../model/post_scope.dart';
import '../model/timeline_type.dart';

enum Formatting { plainText, markdown, html, mfm }

/// 本文の文字数を**サーバーがどう数えるか** (#1034)。
///
/// ⚠⚠ **上限値 ([AdapterCapabilities.maxPostContentLength]) だけでは足りない。**
/// 同じ 500 でも、何を 1 文字と数えるかが両上流で違う。揃えないと
/// **カウンタが赤いのにサーバーは受け付ける**（あるいは逆）になる。
///
/// 数え方の実装は app 側の `util/post_text_length.dart`（書記素を数えるのに
/// `characters` が要るため、依存 0 のこのパッケージには置かない）。
enum PostLengthRule {
  /// **書記素クラスタ**で数え、URL を一律 23 文字へ、メンションをドメイン部
  /// なしへ短縮し、**CW (`spoiler_text`) も同じ枠**で数える。
  ///
  /// Mastodon の `StatusLengthValidator`:
  /// `countable_length(spoiler_text + countable_text(text)) > MAX_CHARS`。
  shortenedGraphemes,

  /// **コードポイント**をそのまま数える。URL もメンションも短縮せず、CW は
  /// 別枠（Misskey `notes/create`: `text` 3000 / `cw` 500 の独立した
  /// `maxLength`）。
  codePoints,
}

abstract class AdapterCapabilities {
  Set<PostScope> get supportedScopes;
  Set<Formatting> get supportedFormattings;
  Set<TimelineType> get supportedTimelines;
  int? get maxPostContentLength;

  /// 本文カウンタが使う数え方 (#1034)。
  ///
  /// ⚠ **抽象メンバにしてある。**既定値を持たせると、新しい backend を足した
  /// ときに「どちらの規則か」を考えないまま通ってしまう（黙って片方の規則が
  /// 当たる）。コンパイラに問わせる。
  PostLengthRule get postLengthRule;
}
