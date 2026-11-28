import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../util/action_labels.dart';
import '../screen/post_list_screen.dart';
import '../screen/user_list_screen.dart';
import 'timeline_type_label.dart';

/// タブ / カラムの種別のラベル。[adapter] はそのタブのアカウントのもの。
///
/// ⚠ カラムのラベルは [columnTabLabel] / [columnTabLabelInScope] から呼ぶ。
/// これを直に呼ぶのは、`isMastodon` を自前で持っているタブ UI だけ。
String tabLabel(
  WidgetRef ref,
  TabType tab,
  bool isMastodon,
  DecentralizedBackendAdapter? adapter,
  List<PostList> allLists,
) {
  return switch (tab) {
    TimelineTab(:final type) => timelineTypeLabel(
      ref,
      type,
      isMastodon: isMastodon,
      adapter: adapter,
    ),
    ListTab(:final id, :final name) =>
      name ?? allLists.where((l) => l.id == id).firstOrNull?.title ?? id,
    HashtagTab(:final tag) => hashtagSpecLabel(tag),
    ChannelTab(:final id, :final name) => channelTabLabel(ref, id, name),
    NotificationsTab() => '通知',
    AnnouncementsTab() => 'お知らせ',
    MessagesTab() => 'メッセージ',
    final DeckOnlyTab t => deckOnlyTabLabel(ref, t, adapter),
  };
}

/// カラムの種別のラベルを、[adapter] のアカウントで組む（#1420）。
///
/// ⚠⚠ **カラムのラベルはここを通す。**見出し（`deck_column_view.dart`）・
/// カラム編集のシート（`deck_columns_sheet.dart`）・メニューバーと帯
/// （`home_menu.dart` の `deckColumnMenuLabel`）の 3 か所が、それぞれ
/// `isMastodon` とリストの引き方を写して持っていた（v2.14 のリリース前レビュー）。
/// 写しは片方だけ直されてずれる —— 実際にリストを引く条件がシートだけ違っていた。
String columnTabLabel(
  WidgetRef ref,
  TabType tab,
  DecentralizedBackendAdapter? adapter,
  List<PostList> lists,
) {
  final isMastodon =
      adapter != null &&
      !adapter.capabilities.supportedTimelines.contains(TimelineType.social);
  return tabLabel(ref, tab, isMastodon, adapter, lists);
}

/// 周りのスコープ（カラムのアカウント）で [tab] のラベルを出す（#1420）。
///
/// 見出しとカラム編集のシートが使う。ルートのスコープで組むメニューバーと帯は
/// `deckColumnMenuLabel` が [columnTabLabel] を直に呼ぶ。
///
/// リスト名はキーに持たない（決定済み事項 4）ので、実行時に一覧から引く。
/// ⚠ リスト以外のカラム・リストに対応しないアカウントで、一覧の取得を起こさない。
String columnTabLabelInScope(WidgetRef ref, TabType tab) {
  final adapter = ref.watch(currentAdapterProvider);
  final lists = tab is ListTab && adapter is ListSupport
      ? ref.watch(listsProvider).valueOrNull ?? const <PostList>[]
      : const <PostList>[];
  return columnTabLabel(ref, tab, adapter, lists);
}

/// デッキ専用のカラム種別（[DeckOnlyTab]）の見出し・アイコン・取得 (#1148 / #1150)。
///
/// ⚠ **タブ UI（全画面の push）とデッキのカラムで同じものを使う。**片方だけで
/// 見出しや取得先を組むと、同じ一覧が出し方によって別物になる。

/// 見出し。[adapter] は周りのスコープ（カラムのアカウント）のもの。
///
/// ⚠ build の外（タップの処理等）で呼ぶときは [listen] を false にする
/// （`ref.watch` を build の外で使わない）。
String deckOnlyTabLabel(
  WidgetRef ref,
  DeckOnlyTab tab,
  DecentralizedBackendAdapter? adapter, {
  bool listen = true,
}) => switch (tab) {
  PostThreadTab() => 'スレッド',
  ProfileTab() => 'プロフィール',
  UserListTab(:final kind) => switch (kind) {
    UserListKind.following => 'フォロー',
    UserListKind.followers => 'フォロワー',
    // ⚠ 三項式を手書きしない（[favouriteLabelFrom] が正本・#1238）。
    UserListKind.favouritedBy => favouriteLabelFrom(adapter),
    UserListKind.rebloggedBy =>
      listen ? ref.watch(reblogLabelProvider) : ref.read(reblogLabelProvider),
    UserListKind.reactedBy => 'リアクション',
  },
  QuotesTab() => kQuotesListTitle,
  AchievementsTab() => '実績',
  CollectionsTab(:final mode) => switch (mode) {
    CollectionsMode.list => 'コレクション',
    CollectionsMode.own => '自分のコレクション',
    CollectionsMode.included => '載っているコレクション',
  },
  CollectionTab() => 'コレクション',
  GalleryPostTab() => 'ギャラリー',
  FlashTab() => 'Play',
  ChatUserTab() => 'メッセージ',
  SearchTab() => '検索',
  AllNotificationsTab() => 'すべての通知',
  AllAnnouncementsTab() => 'すべてのお知らせ',
};

/// カラムの種別のアイコン。カラム編集のシートと、下の帯 (#1241) が共有する。
///
/// ⚠ **2 か所で別々に持たない。**同じカラムが場所によって違うアイコンになると、
/// 帯で見たものをシートで探せない。
IconData deckTabIcon(TabType tab) => switch (tab) {
  TimelineTab() => Icons.forum_outlined,
  ListTab() => Icons.list,
  HashtagTab() => Icons.tag,
  ChannelTab() => Icons.forum,
  NotificationsTab() => Icons.notifications_outlined,
  AnnouncementsTab() => Icons.campaign_outlined,
  MessagesTab() => Icons.chat_bubble_outline,
  final DeckOnlyTab t => deckOnlyTabIcon(t),
};

IconData deckOnlyTabIcon(DeckOnlyTab tab) => switch (tab) {
  PostThreadTab() => Icons.forum_outlined,
  ProfileTab() => Icons.person_outline,
  UserListTab() => Icons.people_outline,
  QuotesTab() => Icons.format_quote,
  AchievementsTab() => Icons.emoji_events_outlined,
  CollectionsTab() || CollectionTab() => Icons.collections_bookmark_outlined,
  GalleryPostTab() => Icons.photo_library_outlined,
  FlashTab() => Icons.play_circle_outline,
  ChatUserTab() => Icons.chat_bubble_outline,
  SearchTab() => Icons.search,
  AllNotificationsTab() => Icons.notifications_active_outlined,
  // ⚠ 1 アカウントのお知らせ（campaign_outlined）と見分ける。すべての通知と同じ形。
  AllAnnouncementsTab() => Icons.campaign,
};

/// ユーザー一覧の取得。アダプタが対応していなければ null。
///
/// ⚠ お気に入り / ブーストは Mastodon と Misskey で呼ぶ API が違う（Misskey に
/// 「お気に入りした人」は無く、リアクションした人全員を出す）。
UserListFetcher? userListFetcher(
  DecentralizedBackendAdapter? adapter,
  UserListTab tab,
) {
  final id = tab.targetId;
  TimelineQuery query(String? cursor) =>
      TimelineQuery(maxId: cursor, limit: 20);
  return switch (tab.kind) {
    UserListKind.following when adapter is FollowSupport =>
      (cursor) =>
          (adapter as FollowSupport).getFollowing(id, query: query(cursor)),
    UserListKind.followers when adapter is FollowSupport =>
      (cursor) =>
          (adapter as FollowSupport).getFollowers(id, query: query(cursor)),
    UserListKind.favouritedBy => switch (adapter) {
      final MastodonAdapter a => (cursor) => a.getFavouritedBy(
        id,
        query: query(cursor),
      ),
      final MisskeyAdapter a => (cursor) => a.getReactedBy(
        id,
        query: query(cursor),
      ),
      _ => null,
    },
    UserListKind.rebloggedBy => switch (adapter) {
      final MastodonAdapter a => (cursor) => a.getRebloggedBy(
        id,
        query: query(cursor),
      ),
      final MisskeyAdapter a => (cursor) => a.getRenotedBy(
        id,
        query: query(cursor),
      ),
      _ => null,
    },
    UserListKind.reactedBy => switch (adapter) {
      final MisskeyAdapter a => (cursor) => a.getReactedBy(
        id,
        type: tab.reaction,
        query: query(cursor),
      ),
      _ => null,
    },
    _ => null,
  };
}

/// 引用の一覧の見出しと、空のときの文面 (#1238)。
///
/// ⚠ 全画面の push（`deck_navigation.dart`）とカラム（`deck_column_view.dart`）が
/// 同じ一覧を出すので、文面を 2 か所に書かない。
const kQuotesListTitle = '引用';
const kQuotesListEmptyMessage = '引用している投稿はありません';

/// 引用した投稿の一覧の取得。アダプタが対応していなければ null。
PostListFetcher? quotesFetcher(
  DecentralizedBackendAdapter? adapter,
  String postId,
) => adapter is QuoteSupport
    ? (cursor) => (adapter as QuoteSupport).getQuotesOf(
        postId,
        query: TimelineQuery(maxId: cursor, limit: 20),
      )
    : null;
