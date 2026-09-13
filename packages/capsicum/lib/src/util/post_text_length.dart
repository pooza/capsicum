/// 本文カウンタを、サーバーが数えるのと同じ規則へ寄せる (#1034)。
///
/// ## なぜ要るか
///
/// 上限値 (`maxPostLengthProvider`) はサーバー由来なのに、**数え方**が
/// [serverTextLength]（コードポイント）固定で、Mastodon と食い違っていた。
///
/// | | 数え方 |
/// | --- | --- |
/// | Mastodon | **書記素** + URL は一律 23 文字 + メンションはドメイン部を落とす + **CW も同じ枠** |
/// | Misskey | **コードポイント**（CW は別枠） |
///
/// ズレは URL で最大になる。100 文字の URL を 1 本貼ると capsicum は 100、
/// サーバーは 23 と数える —— **77 文字ぶん過大**。実況で URL を投げる使い方だと
/// 「カウンタが赤いのにサーバーは通る」が日常的に起きていた。
///
/// ⚠⚠ **CW は逆向き（危険側）にズレる。**Mastodon は
/// `spoiler_text + countable_text(text)` を**ひとつの枠**で数えるので、CW 付き
/// 3000 文字ちょうどの本文は**カウンタが緑のままサーバーが弾く**。上の URL の話は
/// 「余計に赤くなる」だけだが、こちらは投稿が落ちる。
///
/// ## 正本
///
/// `pooza/mastodon` の `app/validators/status_length_validator.rb`:
///
/// ```ruby
/// def too_long?(status)
///   countable_length(combined_text(status)) > MAX_CHARS
/// end
/// def countable_length(str) = str.each_grapheme_cluster.size
/// def combined_text(status) = [status.spoiler_text, countable_text(status.text)].join
/// ```
///
/// ⚠ **CW 側は短縮しない。**`combined_text` が `countable_text` を通すのは本文
/// だけで、`spoiler_text` は生のまま連結される。CW に URL を書いても 23 には
/// ならない。
///
/// ## 近似であることの明示
///
/// ⚠⚠ **entity 抽出は完全一致ではない。**Mastodon は `twitter-text` の
/// `Extractor` を使っており、あちらの URL 正規表現は TLD 一覧まで持っている。
/// ここは「プロトコル付きで、ドットを含むホストがあるもの」を URL とみなす
/// 近似で、境界（末尾の句読点・IDN・括弧の釣り合い）で数文字ぶん外れうる。
///
/// **近似でも現状より確実に近い**という判断 (#1034)。1 本の URL で 77 文字
/// ずれていたものが、ずれても数文字に収まる。
///
/// ⚠ 実際に送るかどうかの判定には使わない。カウンタは表示のみで、送信は
/// 塞いでいない（サーバーの判断に委ねる方針・#1027-F2）。近似がズレても
/// 「投稿できない」にはならない、という前提で近似を許している。
library;

import 'package:capsicum_core/capsicum_core.dart';
import 'package:characters/characters.dart';

import 'text_length.dart';

/// URL を置き換えるプレースホルダの長さ（`URL_PLACEHOLDER_CHARS`）。
const kUrlPlaceholderLength = 23;

/// `MAX_DOMAIN_LENGTH`。これより長いドメインのメンションは entity にしない。
const _maxDomainLength = 253;

/// `URL_PLACEHOLDER` 相当。23 個の `x`。
final _urlPlaceholder = 'x' * kUrlPlaceholderLength;

/// プロトコル付きの URL。
///
/// ⚠ **プロトコル無し（`example.com`）は対象外。**バリデータが
/// `extract_urls_with_indices(str, extract_url_without_protocol: false)` と
/// 明示しているので、`example.com` は短縮されず素の文字数で数えられる。
/// ここを欲張ると、本文中の「〜.jp です」のような普通の日本語を URL と誤認して
/// 23 文字に膨らませてしまう。
///
/// ホストにドットを要求するのは TLD 相当の代用。`http://localhost:3000/x` が
/// 短縮されないのも `twitter-text` と同じ挙動（valid_domain を満たさない）。
///
/// ⚠ 全角スペース (U+3000) は `\s` が含む（ECMAScript の `\s` は Unicode の
/// 空白全部）ので、除外集合に書かない —— **見えない文字をソースに置かない**。
final _urlPattern = RegExp(
  r'https?://'
  r'[\p{L}\p{N}_\-]+(?:\.[\p{L}\p{N}_\-]+)+'
  r'(?::\d+)?'
  r'(?:[/?#][^\s<>"「」『』（）【】]*)?',
  unicode: true,
  caseSensitive: false,
);

/// メンション（`Account::MENTION_RE` の移植）。
///
/// - ユーザー名は ASCII (`[a-z0-9_]` + 区切りの `.` `-`)
/// - ドメイン部は Unicode の word 文字を許す（IDN）
/// - 直前が `=` `/` か word 文字なら対象外 —— URL 中の `/@user` を拾わないため
final _mentionPattern = RegExp(
  r'(?<![=/\p{L}\p{N}_])'
  r'@([a-zA-Z0-9_]+(?:[.\-]+[a-zA-Z0-9_]+)*'
  r'(?:@[\p{L}\p{N}_]+(?:[.\-]+[\p{L}\p{N}_]+)*)?)',
  unicode: true,
);

/// 末尾に句読点や閉じ括弧が食い込んだぶんを URL から外す。
///
/// `https://example.com/a。` の `。`、`(https://example.com/a)` の `)` は URL の
/// 一部ではない。⚠ **括弧は釣り合いを見る** —— `https://ja.wikipedia.org/wiki/(x)`
/// のように URL 自身が括弧を含む場合があるので、開き括弧より閉じ括弧が多いとき
/// だけ落とす。
String _withoutTrailingPunctuation(String url) {
  const closing = {')': '(', ']': '[', '}': '{', '>': '<'};
  const punctuation = '.,;:!?\'"、。，．…';
  var end = url.length;
  while (end > 0) {
    final ch = url[end - 1];
    if (punctuation.contains(ch)) {
      end--;
      continue;
    }
    final open = closing[ch];
    if (open != null) {
      final body = url.substring(0, end);
      final opens = body.split(open).length - 1;
      final closes = body.split(ch).length - 1;
      if (closes > opens) {
        end--;
        continue;
      }
    }
    break;
  }
  return url.substring(0, end);
}

/// 置き換え対象の 1 件。範囲は UTF-16 の index（切り出しに使うだけなので、
/// Ruby 側の codepoint index と混ぜない限り単位は問題にならない）。
class _Entity {
  const _Entity(this.start, this.end, this.replacement);

  final int start;
  final int end;
  final String replacement;
}

/// Mastodon が数える「短縮後の本文」(`countable_text`)。
///
/// URL → 23 文字、`@user@example.com` → `@user`。
String countableText(String text) {
  if (text.isEmpty) return text;

  final entities = <_Entity>[];
  for (final match in _urlPattern.allMatches(text)) {
    final url = _withoutTrailingPunctuation(match[0]!);
    if (url.isEmpty) continue;
    entities.add(
      _Entity(match.start, match.start + url.length, _urlPlaceholder),
    );
  }
  for (final match in _mentionPattern.allMatches(text)) {
    // `end_mention_match` 相当。直後がもう 1 つの `@` や `://` なら、メンション
    // ではなく別の何か（`@user@@x` / `@user://`）なので数に手を入れない。
    final after = text.substring(match.end);
    if (after.startsWith('@') || after.startsWith('://')) continue;

    final parts = match[1]!.split('@');
    if (parts.length > 1 && parts[1].length > _maxDomainLength) continue;
    entities.add(_Entity(match.start, match.end, '@${parts.first}'));
  }

  // `remove_overlapping_entities` 相当。開始位置で並べ、前の entity の内側から
  // 始まるものは捨てる（URL 中のメンションはこれで落ちる）。
  entities.sort((a, b) => a.start.compareTo(b.start));

  final buffer = StringBuffer();
  var index = 0;
  for (final entity in entities) {
    if (entity.start < index) continue;
    buffer.write(text.substring(index, entity.start));
    buffer.write(entity.replacement);
    index = entity.end;
  }
  buffer.write(text.substring(index));
  return buffer.toString();
}

/// 投稿フォームのカウンタが出す数 (#1034)。
///
/// ⚠⚠ **CW 欄に文字が残っていても、[cwEnabled] が false なら数えない。**compose は
/// CW を閉じても `_cwController` の中身を保持する（開き直したとき戻ってくる）
/// 作りなので、欄の中身をそのまま足すと**送らない文字で赤くなる**。
///
/// ⚠ trim するのは `_submit` が `spoilerText` を trim して送るため。表示と送信で
/// 別の文字列を数えない。
int composePostLength(
  PostLengthRule rule, {
  required String text,
  required bool cwEnabled,
  required String cw,
}) => postTextLength(rule, text, cw: cwEnabled ? cw.trim() : '');

/// 本文カウンタが出す数。[rule] はサーバー（adapter）が持つ。
///
/// ⚠ **[cw] を渡すのは呼び出し側の責務。**[PostLengthRule.codePoints]
/// （Misskey）では CW が別枠なので**捨てる**。渡す側で「Mastodon のときだけ
/// 渡す」と分岐させると、規則を片方しか知らない実装が黙って通る。
int postTextLength(PostLengthRule rule, String text, {String cw = ''}) {
  switch (rule) {
    case PostLengthRule.shortenedGraphemes:
      return (cw + countableText(text)).characters.length;
    case PostLengthRule.codePoints:
      return serverTextLength(text);
  }
}
