/// ハッシュタグ TL の指定（spec）の表し方 (#1159)。
///
/// capsicum は「タグ 1 つ」も「AND 指定の組」も **`+` で連結した 1 本の文字列**で
/// 表し、そのまま `hashtag:<spec>` として保存している（タブ設定・デッキのカラム列）。
///
/// ⚠⚠ **Misskey のハッシュタグは `+` を含みうる。**`#c++` はダイスキーに実在する
/// （2026-09-19 実測）。素朴に `split('+')` すると `c` と空タグ 2 つに割れて、
/// **そのタグの TL にならない**。⚠ Mastodon は `+` を許さないので、これは Misskey
/// 側の事情。
///
/// そこで **タグに含まれる `+` をエスケープしてから連結する**。区切りを別の文字へ
/// 変えたり spec を配列にしたりする案もあったが、**保存済みの値を読み替える移行が
/// 要る**のに対し、この方式は移行が要らない（下記）。
///
/// ## エスケープの規則
///
/// | 元 | spec の中 |
/// | --- | --- |
/// | `+` | `%2B` |
/// | `%` | `%25` |
///
/// ⚠ **既存の保存値はそのまま読める。**エスケープを導入する前の spec に `%25` /
/// `%2B` が入っていることは無い（そう書けた入口が無い）ので、[HashtagQuery.parse]
/// にかけても今までと同じタグへ分解される。**移行の読み替えは不要。**
///
/// ⚠ **spec を割る入口は [HashtagQuery.parse] だけ。**以前は含む側のタグを平らに
/// 返す `hashtagSpecTags` があったが、「すべて含む」と「いずれか」を混ぜて返す
/// ので、条件が要る場面で使うと誤る。呼び出しが無くなったので消した (#1283)。
///
/// ⚠ 唯一の穴は、**文字列として `%2B` を含むタグ**（`#a%2Bb`）を後から
/// エスケープ無しで保存していた場合。⚠ **その入口は無い**（新しく作る spec は必ず
/// [hashtagSpecFromTags] を通す）ので、実際には起きない。
library;

const _plusEscape = '%2B';
const _percentEscape = '%25';
// 条件の節の区切り (#1209)。両 SNS ともタグには入らない文字だが、連合してきた
// タグに紛れていても節として読まないよう、同じくエスケープする。
const _questionEscape = '%3F';
const _bangEscape = '%21';

/// タグ 1 つを spec の 1 要素へ変換する。
String _escapeTag(String tag) => tag
    .replaceAll('%', _percentEscape)
    .replaceAll('+', _plusEscape)
    .replaceAll('?', _questionEscape)
    .replaceAll('!', _bangEscape);

String _unescapeTag(String part) => part
    .replaceAll(_plusEscape, '+')
    .replaceAll(_questionEscape, '?')
    .replaceAll(_bangEscape, '!')
    .replaceAll(_percentEscape, '%');

/// タグの列から spec を組み立てる。⚠ **spec を作るときは必ずここを通す。**
///
/// 空のタグは落とす（`+` だけの入力等で空タグが混ざると、サーバーへ空のタグを
/// 問い合わせることになる）。
String hashtagSpecFromTags(Iterable<String> tags) =>
    tags.where((t) => t.isNotEmpty).map(_escapeTag).join('+');

/// タグ 1 つから spec を作る。⚠ **サーバーから受け取ったタグ名**（投稿の `tags`
/// 配列・本文中のタップ・フィーチャータグ等）は必ずここを通す。`+` を含むタグを
/// 素のまま spec にすると AND 指定として割れる。
String hashtagSpecFromTag(String tag) => hashtagSpecFromTags([tag]);

/// ハッシュタグ TL の条件 (#1209)。
///
/// 「[all] を**すべて**含み、（[any] があれば）そのうち**いずれか**を含み、
/// [none] を**どれも含まない**」投稿。
///
/// ## spec の形
///
/// `<all>?<any>!<none>`。各節はタグを `+` でつなぐ。`?` 以降と `!` 以降は無ければ
/// 書かない。
///
/// | 条件 | spec |
/// | --- | --- |
/// | a | `a` |
/// | a かつ b | `a+b` |
/// | a または b | `?a+b` |
/// | a かつ（b または c）・d は除く | `a?b+c!d` |
///
/// ⚠⚠ **以前からの spec（タグ 1 つ・`+` の AND 指定）は、そのまま [all] として
/// 読める。**保存済みの値を読み替える移行は要らない。
///
/// ⚠ 区切りに `?` と `!` を選んだのは、**両 SNS ともタグに使えない文字**だから
/// （Mastodon は語を作る文字だけ。Misskey の MFM も `.,!?'"#:/[]()<>` と空白で
/// タグを切る）。念のため、タグに入っていたらエスケープする（`+` と同じ扱い）。
///
/// ⚠ **[any] が 1 つだけなら [all] へ寄せる**（「a のいずれか」は「a を含む」と
/// 同じ）。同じ条件が 2 通りの spec になると、タブやカラムの重複の判定が割れる。
class HashtagQuery {
  HashtagQuery({
    Iterable<String> all = const [],
    Iterable<String> any = const [],
    Iterable<String> none = const [],
  }) : this._normalized(_clean(all), _clean(any), _clean(none));

  HashtagQuery._normalized(
    List<String> all,
    List<String> any,
    List<String> none,
  ) : all = List.unmodifiable(any.length == 1 ? _clean([...all, ...any]) : all),
      any = List.unmodifiable(any.length == 1 ? const <String>[] : any),
      none = List.unmodifiable(none);

  /// spec から読む。⚠ **spec を割るときは必ずここを通す。**
  factory HashtagQuery.parse(String spec) {
    final bang = spec.indexOf('!');
    final positive = bang < 0 ? spec : spec.substring(0, bang);
    final question = positive.indexOf('?');
    return HashtagQuery(
      all: _splitPart(
        question < 0 ? positive : positive.substring(0, question),
      ),
      any: question < 0
          ? const []
          : _splitPart(positive.substring(question + 1)),
      none: bang < 0 ? const [] : _splitPart(spec.substring(bang + 1)),
    );
  }

  /// すべて含む（AND）。
  final List<String> all;

  /// いずれかを含む（OR）。空か、2 つ以上。
  final List<String> any;

  /// どれも含まない（除外）。
  final List<String> none;

  /// 含む側の条件が 1 つも無い。⚠ 除外だけの条件は TL にならない（全投稿から
  /// 引くことになる）ので、これが true の条件は保存しない。
  bool get isEmpty => all.isEmpty && any.isEmpty;

  /// タグ 1 つだけの条件なら、そのタグ。タグのフォローや、タグ 1 つしか受けない
  /// ストリームを張れるかの判定に使う。
  String? get singleTag =>
      all.length == 1 && any.isEmpty && none.isEmpty ? all.single : null;

  /// spec へ書く。⚠ **spec を作るときは必ずここ（か [hashtagSpecFromTags]）を通す。**
  String toSpec() => [
    hashtagSpecFromTags(all),
    if (any.isNotEmpty) '?${hashtagSpecFromTags(any)}',
    if (none.isNotEmpty) '!${hashtagSpecFromTags(none)}',
  ].join();

  /// 「タグ 1 つ + `any[]` + `all[]`」の形（Mastodon の `timelines/tag/:hashtag`）。
  /// パスのタグと `any[]` が OR、`all[]` が AND になる。条件が空なら null。
  ({String primary, List<String> any, List<String> all})? get tagFeedRequest {
    if (any.isNotEmpty) {
      return (primary: any.first, any: any.sublist(1), all: all);
    }
    if (all.isEmpty) return null;
    return (primary: all.first, any: const [], all: all.sublist(1));
  }

  /// 「外側が OR・内側が AND」の 2 次元配列（Misskey の `notes/search-by-tag` の
  /// `query`・ストリーミングの `hashtag` チャンネルの `q`）。条件が空なら空。
  ///
  /// ⚠ **[none] は入らない**（受け口が無い）。除外は [excludes] で端末側が見る。
  List<List<String>> get orOfAnds {
    if (isEmpty) return const [];
    if (any.isEmpty) return [all];
    return [
      for (final tag in any) [tag, ...all],
    ];
  }

  /// [tags]（投稿のタグ）が [none] のどれかを含むか。大小は区別しない。
  bool excludes(Iterable<String> tags) {
    if (none.isEmpty) return false;
    final lower = {for (final t in tags) t.toLowerCase()};
    return none.any((t) => lower.contains(t.toLowerCase()));
  }

  /// [tags]（投稿のタグ）が、`all[]` で送ったタグのどれかを欠いているか (#1283)。
  ///
  /// **サーバーが返した一覧を、端末側で確かめ直すためのもの。**Mastodon の
  /// `timelines/tag/:hashtag` は、`all[]` のうちサーバーに実在しないタグを黙って
  /// 落とす（上流の `TagFeed#tags_for` は実在するタグの id だけを返す）。
  /// 「a かつ 誰も使っていないタグ」は AND が外れ、`#a` の全件が返ってくる。
  ///
  /// ⚠⚠ **[matches] をそのまま当てない。**サーバーはタグを正規化して比べる
  /// （全角英数 → 半角・アクセントを外す など）ので、端末側の素朴な比較は、
  /// 正規化で形が変わるタグを「欠いている」と読み違える。読み違えると、合って
  /// いる投稿が全部落ちて TL が空になる —— 直そうとしている不具合より悪い。
  /// → **正規化で形が変わらないと言えるタグだけを確かめる**（[_comparesReliably]）。
  /// それ以外のタグは、従来どおりサーバーの結果を信じる。
  ///
  /// ⚠⚠ **確かめるのは `all[]` で送るタグだけ**（[tagFeedRequest] の `all`）。
  /// パスに載せる 1 つ目のタグは見ない —— 実在しなければサーバーは空を返すので、
  /// 黙って外れることが無い。＝ **タグ 1 つだけの TL（プリセットのデフォルト
  /// ハッシュタグを含む）は、ここで 1 件も落ちない。**
  bool lacksRequired(Iterable<String> tags) {
    final sent = tagFeedRequest?.all ?? const <String>[];
    if (sent.isEmpty) return false;
    final lower = {for (final t in tags) t.toLowerCase()};
    return sent.any(
      (t) => _comparesReliably(t) && !lower.contains(t.toLowerCase()),
    );
  }

  /// サーバーの正規化（NFKC・アクセントの除去）で形が変わらないと言えるタグか。
  ///
  /// 半角の英数字とアンダースコア、ひらがな・全角カタカナ、漢字だけで出来て
  /// いるもの。⚠ 全角英数・半角カナ・アクセント付きの文字は正規化で変わるので、
  /// 1 文字でも含めば false。
  static bool _comparesReliably(String tag) => _reliableTag.hasMatch(tag);

  static final _reliableTag = RegExp(r'^[A-Za-z0-9_ぁ-ゖァ-ヺー一-鿿]+$');

  /// [tags]（投稿のタグ）がこの条件に合うか。大小は区別しない（両 SNS とも
  /// 区別しない）。
  bool matches(Iterable<String> tags) {
    if (isEmpty) return false;
    final lower = {for (final t in tags) t.toLowerCase()};
    bool has(String tag) => lower.contains(tag.toLowerCase());
    return all.every(has) && (any.isEmpty || any.any(has)) && !none.any(has);
  }

  /// この TL から投稿するときに付けるタグ。[all] の全部と、[any] の先頭。
  ///
  /// ⚠ [any] を全部付けない —— 「a または b」の TL から書いた投稿に両方が付くと、
  /// 利用者が選んでいないタグまで付く。先頭 1 つで、この TL には載る。
  List<String> get tagsToPost => [...all, if (any.isNotEmpty) any.first];

  @override
  bool operator ==(Object other) =>
      other is HashtagQuery && other.toSpec() == toSpec();

  @override
  int get hashCode => toSpec().hashCode;

  @override
  String toString() => 'HashtagQuery(${toSpec()})';
}

List<String> _splitPart(String part) => [
  for (final piece in part.split('+'))
    if (piece.isNotEmpty) _unescapeTag(piece),
];

/// 空と重複（大小を区別しない）を落とす。先に出たほうを残す。
List<String> _clean(Iterable<String> tags) {
  final seen = <String>{};
  return [
    for (final tag in tags)
      if (tag.isNotEmpty && seen.add(tag.toLowerCase())) tag,
  ];
}
