import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/deck_column.dart';
import '../../provider/channel_provider.dart';
import 'provider_scope_carrier.dart';

/// カラムの見出しに新規投稿の入口を出すか (#1172)。
///
/// ⚠⚠ **チャンネルのカラムは `ChannelSupport` が要る。**`channelId` を渡せない
/// バックエンドで開くと**チャンネルの外へ投稿が出る**ので、入口自体を出さない
/// （`channel_timeline_screen` の `canPost` と同じ判定）。
///
/// ⚠ メッセージはフィードを持たない遷移トリガー (#439) でカラムにならないため、
/// 中身も「表示できません」になる。投稿の入口も出さない。
bool canComposeFromColumn(TabType tab, DecentralizedBackendAdapter? adapter) {
  if (adapter == null) return false;
  return switch (tab) {
    MessagesTab() => false,
    ChannelTab() => adapter is ChannelSupport,
    _ => true,
  };
}

/// カラムから新規投稿を開くときの初期状態 (#1172・`docs/deck-ui-plan.md`
/// 決定済み事項 10)。
///
/// | カラム | 初期状態 |
/// | --- | --- |
/// | ハッシュタグ | 本文の末尾に `#タグ`（AND 指定なら全部） |
/// | チャンネル（Misskey） | **そのチャンネルへの投稿**（`channelId`） |
/// | その他 | 空 |
///
/// ⚠⚠ **チャンネルの `channelId` は必須。**落とすとチャンネルの外へ投稿が出る。
///
/// ⚠ **spec をそのままタグとして渡さない** (#1159)。`HashtagTab.tag` は AND 連結と
/// エスケープを含む内部表現なので、[hashtagSpecTags] で分解してから渡す。
/// そのまま渡すと `#c%2B%2B` のような実在しないタグで投稿してしまう。
///
/// ⚠ [channels] は**そのカラムのアカウント**のフォロー中チャンネル。読み戻した
/// カラムの `ChannelTab.name` が null なのでここから引く。引く側を呼び出し元に
/// 任せているのは、**メニューバーからも呼ぶ**ため —— メニューは ShellRoute に
/// 常駐していてルートのスコープで動くので、`WidgetRef` を渡す形だと別アカウントの
/// 一覧を引いてしまう (#1170)。
Map<String, dynamic> deckComposeExtra(
  DeckColumn column, {
  List<Channel> channels = const [],
}) {
  return switch (column.tab) {
    HashtagTab(:final tag) => {'hashtags': hashtagSpecTags(tag)},
    ChannelTab(:final id, :final name) => {
      'channelId': id,
      // ⚠ 読み戻したカラムの `name` は null（保存キーが [TabType.toIdentityKey]
      // なので表示名を含まない・決定済み事項 4-1）。
      'channelName':
          name ?? channels.where((c) => c.id == id).firstOrNull?.name,
    },
    _ => const <String, dynamic>{},
  };
}

/// [deckComposeExtra] に渡すチャンネルの一覧を、周りのスコープから読む。
///
/// ⚠ フォロー中チャンネルの一覧は `visibleTabsProvider` が常時 watch しているので、
/// 引くのは安い（新しく取得は起こらない）。
List<Channel> deckChannelsInScope(WidgetRef ref) =>
    ref.read(followedChannelsProvider).valueOrNull ?? const [];

/// [column] のアカウントで新規投稿を開く (#1172)。
///
/// ⚠⚠ **`extraWithProviderScope` を通す。**素の `push('/compose')` だと、別
/// アカウントのカラムから開いても**現在のアカウント**として投稿される
/// （`provider_scope_push_guard_test` が落とす）。
Future<void> openDeckCompose(
  BuildContext context,
  WidgetRef ref,
  DeckColumn column,
) async {
  final extra = extraWithProviderScope(
    context,
    deckComposeExtra(column, channels: deckChannelsInScope(ref)),
  );
  await context.push<bool>('/compose', extra: extra);
}
