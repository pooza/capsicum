import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../util/post_actions.dart';
import '../util/post_scope_display.dart';
import 'reaction_picker_sheet.dart';

/// 投稿 / 通知タイル上のタッチ操作ボタン行を集約した共有 widget (#657)。
///
/// 機能自体は #565（タッチ操作のオプトイン）由来で、post_tile と
/// notification_tile に約 90 行が重複していたため本 widget に集約した。
/// [postTouchActionsProvider] で端末ごとに有効化され、かつ
/// adapter が対応しているアクションだけを小さな [IconButton] として並べる。
/// 該当が無ければ [SizedBox.shrink]。長押しメニュー / 「…」ボタンは設定に
/// 関係なく各タイル側に併存する。
class PostTouchActionRow extends ConsumerWidget {
  /// アクション対象（reblog 解決済みの投稿）。
  final Post targetPost;

  /// タイムライン上の外側 post。自分のリノートの取り消し判定と、取り消し時の
  /// `removePost` に使う。reblog でない場合は [targetPost] と同じものを渡す。
  final Post outerPost;

  /// favorite / boost 等で post が更新されたとき親へ通知する（任意）。
  final ValueChanged<Post>? onPostUpdated;

  /// アクション完了後のフック（任意。タイムライン再取得等）。
  final VoidCallback? onActionCompleted;

  const PostTouchActionRow({
    super.key,
    required this.targetPost,
    required this.outerPost,
    this.onPostUpdated,
    this.onActionCompleted,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(postTouchActionsProvider);
    if (enabled.isEmpty) return const SizedBox.shrink();

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return const SizedBox.shrink();

    final messenger = ScaffoldMessenger.of(context);
    final buttons = <Widget>[];

    void add(IconData icon, String tooltip, VoidCallback onPressed) {
      buttons.add(
        IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(),
          color: Theme.of(context).textTheme.bodySmall?.color,
          onPressed: onPressed,
        ),
      );
    }

    if (enabled.contains(PostTouchAction.reply)) {
      add(Icons.reply, 'リプライ', () {
        context.push('/compose', extra: {'replyTo': targetPost});
      });
    }
    if (enabled.contains(PostTouchAction.favorite) &&
        adapter is FavoriteSupport) {
      // 状態に応じて追加 / 解除をトグルする (#565)。
      if (targetPost.favourited) {
        add(Icons.star, 'お気に入りを解除', () {
          _runAction(
            ref,
            messenger,
            () => (adapter as FavoriteSupport).unfavoritePost(targetPost.id),
            'お気に入りを解除しました',
          );
        });
      } else {
        add(Icons.star_outline, 'お気に入り', () {
          _runAction(
            ref,
            messenger,
            () => (adapter as FavoriteSupport).favoritePost(targetPost.id),
            'お気に入りに追加しました',
          );
        });
      }
    }
    if (enabled.contains(PostTouchAction.reaction) &&
        adapter is ReactionSupport) {
      add(Icons.add_reaction_outlined, 'リアクション', () {
        _showEmojiPicker(context, ref);
      });
    }
    if (enabled.contains(PostTouchAction.bookmark) &&
        adapter is BookmarkSupport) {
      // Misskey の「お気に入り」は Mastodon のブックマーク相当（Mastodon の
      // お気に入り=FavoriteSupport とは別機能）(#855)。状態に応じてトグルする。
      final bookmarkLabel = adapter is ReactionSupport ? 'お気に入り' : 'ブックマーク';
      if (targetPost.bookmarked) {
        add(Icons.bookmark, '$bookmarkLabelを解除', () {
          _runAction(
            ref,
            messenger,
            () => (adapter as BookmarkSupport).unbookmarkPost(targetPost.id),
            '$bookmarkLabelを解除しました',
          );
        });
      } else {
        add(Icons.bookmark_outline, bookmarkLabel, () {
          _runAction(
            ref,
            messenger,
            () => (adapter as BookmarkSupport).bookmarkPost(targetPost.id),
            '$bookmarkLabelに追加しました',
          );
        });
      }
    }
    if (enabled.contains(PostTouchAction.boost)) {
      final boostLabel = ref.read(reblogLabelProvider);
      final currentUser = ref.read(currentAccountProvider)?.user;
      final isOwnRenote =
          outerPost.reblog != null &&
          currentUser != null &&
          outerPost.author.id == currentUser.id;
      final canUnrepeat = isOwnRenote || targetPost.reblogged;
      // 既にブースト済み（自分のリノート or reblogged）なら取り消しに切り替える
      // (#561 のタッチ操作側対応)。長押しメニューと同じトグル挙動。
      if (canUnrepeat) {
        add(Icons.repeat_on, '$boostLabelを取り消す', () {
          _unrepeat(ref, messenger, adapter, isOwnRenote, boostLabel);
        });
      } else if (targetPost.scope == PostScope.public ||
          targetPost.scope == PostScope.unlisted) {
        add(Icons.repeat, boostLabel, () {
          _runTouchBoost(context, ref, adapter, boostLabel);
        });
      }
    }
    if (enabled.contains(PostTouchAction.quote) && targetPost.quotable) {
      add(Icons.format_quote, '引用', () {
        context.push('/compose', extra: {'quoteTo': targetPost});
      });
    }

    if (buttons.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
    );
  }

  /// タッチ操作からのブースト / リノート (#565)。公開範囲を選べる場合
  /// （元投稿が public）は長押しメニューと同じ chip シートを開いてから実行、
  /// それ以外は即時実行する。
  void _runTouchBoost(
    BuildContext context,
    WidgetRef ref,
    BackendAdapter adapter,
    String boostLabel,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    final scopes = boostableScopes(targetPost.scope);
    if (scopes.isEmpty) {
      _runAction(
        ref,
        messenger,
        () => adapter.repeatPost(targetPost.id),
        '$boostLabelしました',
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.repeat),
              title: Text('$boostLabelの公開範囲'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Wrap(
                spacing: 8,
                children: scopes.map((scope) {
                  final display = postScopeDisplay(scope, adapter);
                  return ActionChip(
                    avatar: Icon(display.icon, size: 16),
                    label: Text(display.label),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _runAction(
                        ref,
                        messenger,
                        () => adapter.repeatPost(
                          targetPost.id,
                          visibility: scope,
                        ),
                        '$boostLabelしました（${display.label}）',
                      );
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 実行と失敗の扱いは [PostActionRunner] に寄せた (#943)。この 3 本は
  /// `post_tile` に同名・同構造の双子がおり、片方だけ直して `phase: post_action`
  /// の母数からこの導線が欠ける事故を繰り返していた。
  PostActionRunner _runner(WidgetRef ref, ScaffoldMessengerState messenger) =>
      PostActionRunner(
        ref: ref,
        messenger: messenger,
        onPostUpdated: onPostUpdated,
        onActionCompleted: onActionCompleted,
      );

  /// ブースト / リノートの取り消し (#561)。
  Future<void> _unrepeat(
    WidgetRef ref,
    ScaffoldMessengerState messenger,
    BackendAdapter adapter,
    bool isOwnRenote,
    String boostLabel,
  ) => _runner(ref, messenger).unrepeat(
    adapter: adapter,
    outerPost: outerPost,
    targetPost: targetPost,
    isOwnRenote: isOwnRenote,
    boostLabel: boostLabel,
  );

  void _showEmojiPicker(BuildContext context, WidgetRef ref) {
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    if (account == null || adapter is! ReactionSupport) return;

    final messenger = ScaffoldMessenger.of(context);
    // onSelected は遅延実行される。実行時点で currentAccountProvider が
    // 入れ替わっていても安全なよう、ここで確定した非 null 値をローカルへ退避し、
    // closure 内で `!` / `as` を再評価しない
    // （CAPSICUM-32 #739: closure 実行時の Null check operator クラッシュ対策）。
    final backend = adapter as BackendAdapter;
    final reaction = adapter as ReactionSupport;

    unawaited(
      showReactionPickerSheet(
        context: context,
        ref: ref,
        onSelected: (emoji) => _runReactionAction(
          ref,
          messenger,
          backend,
          () => reaction.addReaction(targetPost.id, emoji),
          'リアクションしました',
        ),
      ),
    );
  }

  Future<void> _runReactionAction(
    WidgetRef ref,
    ScaffoldMessengerState messenger,
    BackendAdapter adapter,
    Future<void> Function() action,
    String successMessage, {
    String phase = 'reaction_add',
  }) => _runner(
    ref,
    messenger,
  ).runReaction(adapter, targetPost.id, action, successMessage, phase: phase);

  Future<void> _runAction(
    WidgetRef ref,
    ScaffoldMessengerState messenger,
    Future<Post> Function() action,
    String successMessage,
  ) => _runner(ref, messenger).run(action, successMessage);
}
