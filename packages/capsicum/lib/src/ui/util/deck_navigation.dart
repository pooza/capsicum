import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/deck_column.dart';
import '../../provider/account_manager_provider.dart';
import 'deck_tabs.dart';

/// デッキのカラムの中であることを示す (#1148)。
///
/// ⚠ **`InheritedTheme` なのは、カラムから開いたシート・ダイアログ・メニューの中
/// にも持ち込むため**（`ProviderScopeCarrier` と同じ仕組み・#1149）。投稿の長押し
/// シートの「プロフィールを表示」やハッシュタグのシートから開いても、元のカラムの
/// 右隣に足される。
///
/// ⚠ 全画面の push（投稿フォーム等）の先には持ち込まれない。そこから開くものは
/// 今どおり push になる。
class DeckColumnScope extends InheritedTheme {
  const DeckColumnScope({
    super.key,
    required this.column,
    required this.onOpen,
    required this.onClose,
    required super.child,
  });

  /// 開く元のカラム。新しいカラムはこの右隣に、このアカウントで足す。
  final DeckColumn column;

  /// カラムを足す（デッキ画面が渡す。列への挿入と、足したカラムを見える位置まで
  /// 送るのを受け持つ）。
  final void Function(DeckColumn from, TabType tab, Object? seed) onOpen;

  /// カラムを列から外す（中身の画面が「閉じる」とき・#1150）。
  final void Function(DeckColumn column) onClose;

  static DeckColumnScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DeckColumnScope>();

  @override
  Widget wrap(BuildContext context, Widget child) => DeckColumnScope(
    column: column,
    onOpen: onOpen,
    onClose: onClose,
    child: child,
  );

  @override
  bool updateShouldNotify(DeckColumnScope oldWidget) =>
      // ⚠ onOpen はメソッドのテアオフで渡るので、identical ではなく == で比べる
      // （テアオフはビルドのたびに別インスタンスだが等価）。
      !identical(column, oldWidget.column) ||
      onOpen != oldWidget.onOpen ||
      onClose != oldWidget.onClose;
}

/// デッキのカラムの中なら [tab] を右隣のカラムとして足し、外なら [push] する。
///
/// ⚠⚠ **カラムの中身から開く画面は、必ずここ（か下の `open*`）を通す。**素の
/// `context.push` は、**カラム B から開いた画面をアカウント A（ルート）で動かす。**
/// id はサーバーローカルなので、B のユーザー id を A で引いて別人を指しうる
/// （#1150）。`deck_navigation_guard_test` が止める。
///
/// 戻り値は push の結果（カラムに足したときは null ですぐ完了する）。
Future<T?> openColumnOrPush<T>(
  BuildContext context,
  TabType tab, {
  Object? seed,
  required Future<T?> Function() push,
}) {
  final deck = DeckColumnScope.maybeOf(context);
  if (deck != null) {
    deck.onOpen(deck.column, tab, seed);
    return Future.value();
  }
  return push();
}

/// 画面を閉じる関数を返す (#1150)。カラムの中ならカラムを外し、外なら pop する。
///
/// ⚠ **`await` の前に取っておくこと**（`Navigator.of(context)` を先に取るのと
/// 同じ理由）。⚠ **ダイアログを閉じるのに使わない**（カラムから開いたダイアログ
/// にも [DeckColumnScope] は持ち込まれているので、カラムごと消える）。
VoidCallback screenCloser(BuildContext context) {
  final deck = DeckColumnScope.maybeOf(context);
  if (deck != null) return () => deck.onClose(deck.column);
  final navigator = Navigator.of(context);
  return () => navigator.pop();
}

/// 投稿（スレッド）を開く (#1148)。
void openPost(BuildContext context, Post post) => openColumnOrPush(
  context,
  PostThreadTab(post.id),
  seed: post,
  push: () => context.push('/post', extra: post),
);

/// プロフィールを開く (#1148)。
void openProfile(BuildContext context, User user) => openColumnOrPush(
  context,
  ProfileTab(user.id),
  seed: user,
  push: () => context.push('/profile', extra: user),
);

/// ハッシュタグのタイムラインを開く (#1148)。
///
/// [tag] は先頭の `#` を除いたタグ名（AND 条件の `a+b` もそのまま）。
void openHashtag(BuildContext context, String tag) => openColumnOrPush(
  context,
  HashtagTab(tag),
  push: () => context.push('/hashtag/$tag'),
);

/// チャンネルのタイムラインを開く (#1150)。
void openChannel(BuildContext context, String id, String? name) =>
    openColumnOrPush(
      context,
      ChannelTab(id: id, name: name),
      push: () => context.push('/channel/$id', extra: name),
    );

/// ユーザー一覧（フォロー / フォロワー / 反応した人）を開く (#1150)。
///
/// アダプタが対応していなければ何もしない。
void openUserList(BuildContext context, WidgetRef ref, UserListTab tab) {
  final adapter = ref.read(currentAdapterProvider);
  final fetcher = userListFetcher(adapter, tab);
  if (fetcher == null) return;
  openColumnOrPush(
    context,
    tab,
    push: () => context.push(
      '/users',
      extra: {
        'title': deckOnlyTabLabel(ref, tab, adapter, listen: false),
        'fetcher': fetcher,
      },
    ),
  );
}

/// その投稿を引用した投稿の一覧を開く (#1150)。
void openQuotes(BuildContext context, WidgetRef ref, String postId) {
  final fetcher = quotesFetcher(ref.read(currentAdapterProvider), postId);
  if (fetcher == null) return;
  openColumnOrPush(
    context,
    QuotesTab(postId),
    push: () => context.push(
      '/posts',
      extra: {
        'title': '引用',
        'emptyMessage': '引用している投稿はありません',
        'fetcher': fetcher,
      },
    ),
  );
}

/// 実績の一覧を開く (#1150)。[displayName] は見出し用（保存しない）。
void openAchievements(
  BuildContext context, {
  required String userId,
  String? displayName,
}) => openColumnOrPush(
  context,
  AchievementsTab(userId),
  seed: displayName,
  push: () => context.push(
    '/achievements',
    extra: {'userId': userId, 'displayName': displayName},
  ),
);

/// コレクションの一覧を開く (#1150)。
void openCollections(
  BuildContext context,
  WidgetRef ref, {
  required String accountId,
  required CollectionsMode mode,
}) {
  final tab = CollectionsTab(accountId, mode);
  openColumnOrPush(
    context,
    tab,
    push: () => context.push(
      '/collections',
      extra: {
        'accountId': accountId,
        'inCollections': mode == CollectionsMode.included,
        'ownerView': mode == CollectionsMode.own,
        'title': deckOnlyTabLabel(ref, tab, null, listen: false),
      },
    ),
  );
}

/// コレクション 1 つを開く (#1150)。全画面なら閉じるまで待つ（一覧の再読込用）。
Future<void> openCollection(BuildContext context, String collectionId) =>
    openColumnOrPush<void>(
      context,
      CollectionTab(collectionId),
      push: () => context.push('/collection', extra: collectionId),
    );

/// ギャラリーの投稿を開く (#1150)。
void openGalleryPost(BuildContext context, GalleryPost post) =>
    openColumnOrPush(
      context,
      GalleryPostTab(post.id),
      seed: post,
      push: () => context.push('/gallery/${post.id}', extra: post),
    );

/// Misskey Play を開く (#1150)。一覧から来たときは [flash] を渡す。
void openFlash(BuildContext context, {Flash? flash, String? flashId}) {
  final id = flash?.id ?? flashId;
  if (id == null) return;
  openColumnOrPush(
    context,
    FlashTab(id),
    seed: flash,
    push: () => context.push(
      '/play',
      extra: flash != null ? {'flash': flash} : {'flashId': id},
    ),
  );
}

/// ユーザーとのメッセージを開く (#1150)。
void openChatWithUser(BuildContext context, User user) => openColumnOrPush(
  context,
  ChatUserTab(user.id),
  seed: user,
  push: () => context.push('/chat/user/${user.id}', extra: user),
);
