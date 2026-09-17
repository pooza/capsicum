import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/server_config_provider.dart';
import '../screen/post_list_screen.dart';
import '../screen/user_list_screen.dart';

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
    UserListKind.favouritedBy =>
      adapter is ReactionSupport ? 'リアクション' : 'お気に入り',
    UserListKind.rebloggedBy =>
      listen ? ref.watch(reblogLabelProvider) : ref.read(reblogLabelProvider),
    UserListKind.reactedBy => 'リアクション',
  },
  QuotesTab() => '引用',
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
