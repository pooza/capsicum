/// DM の会話。投稿（会話の最新の 1 件）が属している単位 (#1206)。
class ConversationRef {
  final String id;

  /// サーバーが未読と見なしているか（最後に DM 一覧を取得した時点）。
  final bool unread;

  const ConversationRef({required this.id, required this.unread});
}

/// DM を「会話」の単位で既読にする・削除する (#1206)。
///
/// capsicum は DM を**投稿の列**として出している（会話の最新の 1 件を並べる）。
/// 既読と削除は会話に対する操作なので、投稿からその会話を引く口が要る。
///
/// ⚠ **Mastodon 専用。**Misskey の DM は chat で別実装。
abstract mixin class ConversationSupport {
  /// [postId] の投稿が属する会話。DM 一覧でまだ取得していなければ null。
  ///
  /// ⚠ **投稿のモデルには持たせていない。**お気に入りなどでサーバーの応答から
  /// 投稿を作り直すと会話の情報が落ちるので、対応はバックエンドの側で持つ。
  ConversationRef? conversationOf(String postId);

  /// 会話を既読にする。⚠ **利用者がその DM を開いたときだけ呼ぶ**（取得した
  /// だけで呼ぶと、WebUI の未読が黙って消える・#1045 と同じ型）。
  Future<void> markConversationRead(String conversationId);

  /// 会話を一覧から消す。⚠ **投稿そのものは消えない**（自分の一覧から畳むだけ）。
  Future<void> deleteConversation(String conversationId);
}
