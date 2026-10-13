import '../../../capsicum_core.dart';

/// リスト TL に出す返信の範囲（Mastodon の `replies_policy`・#1211）。
enum ListRepliesPolicy {
  /// フォローしている人への返信を出す。
  followed('followed'),

  /// リストのメンバーへの返信だけを出す（Mastodon の既定）。
  list('list'),

  /// 返信を出さない。
  none('none');

  const ListRepliesPolicy(this.apiValue);

  /// API で送受信する値。
  final String apiValue;

  /// API の値から読む。知らない値・null は null（＝設定を出さない）。
  static ListRepliesPolicy? fromApi(String? value) {
    for (final policy in values) {
      if (policy.apiValue == value) return policy;
    }
    return null;
  }
}

class PostList {
  final String id;
  final String title;

  /// 以下 3 つはリストの設定 (#1211)。**null は「このサーバーには無い項目」**で、
  /// 画面はその項目を出さない。接続先によって持つ項目が違う（Mastodon は
  /// 返信の範囲とホームからの排他、Misskey は公開）。

  /// リスト TL に出す返信の範囲（Mastodon）。
  final ListRepliesPolicy? repliesPolicy;

  /// リストのメンバーの投稿を、ホーム TL から外すか（Mastodon）。
  ///
  /// ⚠ **リスト TL ではなく、ホーム TL の見え方を変える設定。**
  final bool? exclusive;

  /// リストを公開しているか（Misskey）。
  final bool? isPublic;

  const PostList({
    required this.id,
    required this.title,
    this.repliesPolicy,
    this.exclusive,
    this.isPublic,
  });

  /// 変えられる設定を 1 つでも持っているか。
  bool get hasSettings =>
      repliesPolicy != null || exclusive != null || isPublic != null;
}

abstract mixin class ListSupport {
  Future<List<PostList>> getLists();
  Future<List<Post>> getListTimeline(String listId, {TimelineQuery? query});
  Future<PostList> createList(String title);
  Future<PostList> updateList(String id, String title);

  /// リストの設定を変える (#1211)。**渡した項目だけ**を送る（null は変えない）。
  ///
  /// ⚠ そのサーバーに無い項目（[PostList] で null のもの）は渡さない。渡しても
  /// 実装は送らない。
  Future<PostList> updateListSettings(
    String id, {
    ListRepliesPolicy? repliesPolicy,
    bool? exclusive,
    bool? isPublic,
  });
  Future<void> deleteList(String id);

  /// リストのメンバーを**全員**返す (#1202)。
  ///
  /// ⚠ **ページングしない約束。**バックエンドが既定件数で切る場合は、実装の
  /// 側で全件を取り切る（Mastodon は `limit=0`・Misskey は `userIds` が全件）。
  Future<List<User>> getListAccounts(String listId);
  Future<void> addListAccounts(String listId, List<String> accountIds);
  Future<void> removeListAccounts(String listId, List<String> accountIds);
}
