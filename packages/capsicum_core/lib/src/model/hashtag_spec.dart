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
/// `%2B` が入っていることは無い（そう書けた入口が無い）ので、[hashtagSpecTags] に
/// かけても今までと同じタグへ分解される。**移行の読み替えは不要。**
///
/// ⚠ 唯一の穴は、**文字列として `%2B` を含むタグ**（`#a%2Bb`）を後から
/// エスケープ無しで保存していた場合。⚠ **その入口は無い**（新しく作る spec は必ず
/// [hashtagSpecFromTags] を通す）ので、実際には起きない。
library;

const _plusEscape = '%2B';
const _percentEscape = '%25';

/// タグ 1 つを spec の 1 要素へ変換する。
String _escapeTag(String tag) =>
    tag.replaceAll('%', _percentEscape).replaceAll('+', _plusEscape);

String _unescapeTag(String part) =>
    part.replaceAll(_plusEscape, '+').replaceAll(_percentEscape, '%');

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

/// spec をタグの列へ分解する。⚠ **spec を割るときは必ずここを通す。**
///
/// AND 指定なら 2 つ以上、単独のタグなら 1 つ返る。空のタグは落とす。
List<String> hashtagSpecTags(String spec) => [
  for (final part in spec.split('+'))
    if (part.isNotEmpty) _unescapeTag(part),
];
