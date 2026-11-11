/// カスタム絵文字の URL が手元に無いときに、[host] のサーバーへ直接取りに行く
/// URL (#1372)。
///
/// Mastodon / Misskey とも `/emoji/<shortcode>.webp` で絵文字の画像を返す
/// （Misskey はリダイレクト）。投稿や利用者に絵文字の表が付いていないとき
/// （リアクションの名前だけが分かる・自己紹介の絵文字が欠けている など）の
/// 最後の手段。
///
/// ⚠ 組み立てはここ 1 か所に置く。20 か所に同じ文字列が写されていた。
String fallbackEmojiUrl(String host, String shortcode) =>
    'https://$host/emoji/$shortcode.webp';
