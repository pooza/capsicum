import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../util/exception_scrub.dart';
import '../widget/desktop_menu_model.dart';
import 'post_action_error.dart';
import 'visible_timeline.dart';

/// 投稿アクション（お気に入り / ブースト / ブックマーク / リアクション等）の
/// 実行と結果反映を 1 箇所へ寄せたもの (#943)。
///
/// ## なぜ寄せたか
///
/// 同じ実装が `post_tile` / `post_touch_action_row` / `notification_tile` に
/// **同名・同構造で並んでいた**。片方だけ直すと `phase: post_action` の母数から
/// その導線が欠け、失敗文言も導線ごとに変わる。実際にリリース前レビューで
/// 「3 巡目でこちらだけ直し、4 巡目で向こうの取りこぼしを指摘された」が起きており、
/// 各ファイルのコメントが「次に触るときは対で見ること」と警告していた。
///
/// #943 でアクションをタイルの外（デスクトップメニューバー）からも起こすことに
/// なり、**4 つ目の写しを作るか寄せるかの分かれ道**になったので寄せた。
///
/// ## 使い方
///
/// タイル側は `messenger` と `ref` を渡して 1 つ持つ。⚠ **`messenger` と
/// notifier は await の前に確定させる**のがこのクラスの存在理由の半分で、
/// await 中にタイルが dispose されると `ref.read` が StateError を投げる
/// (#665)。[run] 系は入口で [readVisibleTimelinesOrDetached] を呼んでから
/// スタートする。
///
/// ## await が呼び出し元の外にある経路 (#990)
///
/// 「入口で確定させる」だけでは足りない場合がある。リアクションはボトムシートで
/// 絵文字を選んでもらう形で、**runner が作られる時点で既にタイルが dispose 済み**
/// になりうる（シートが開いている間に背後の TL が更新されると起きる）。この形は
/// 入口の呼び出し自体が投げるので、`action()` へ辿り着かない。
///
/// 対策は 2 段に分けている:
///
/// 1. 呼び出し側が [timeline] を**シートを開く前に**捕まえて渡す（規約どおりの直し方）
/// 2. それでも取れなかったときは [VisibleTimelineMutator.detached] へ落とし、
///    **画面反映だけを諦めてアクションは実行する**
class PostActionRunner {
  const PostActionRunner({
    required this.ref,
    required this.messenger,
    this.timeline,
    this.onPostUpdated,
    this.onActionCompleted,
  });

  final WidgetRef ref;
  final ScaffoldMessengerState messenger;

  /// 反映先の TL。**シート等で await をまたぐ導線は、開く前に捕まえて渡す** (#990)。
  /// null なら実行時に [readVisibleTimelinesOrDetached] で取りにいく。
  final VisibleTimelineMutator? timeline;

  /// 更新後の投稿を呼び出し側へ返す口（タイルのローカル表示更新用）。
  final void Function(Post updated)? onPostUpdated;

  /// アクションが 1 つ完了するたびに呼ぶ（スレッド再取得等）。
  final VoidCallback? onActionCompleted;

  /// 更新後の [Post] を返すアクション（お気に入り / ブースト / ブックマーク /
  /// ピン留め等）。結果をタイムラインへ反映する。
  Future<void> run(
    Future<Post> Function() action,
    String successMessage,
  ) async {
    final timeline = _timeline;
    try {
      final updated = await action();
      timeline.updatePost(updated);
      _notifyPostUpdated(updated);
      _notifyCompleted();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e, st) {
      _report('run', e, st, phase: 'post_action');
    }
  }

  /// 投稿を返さないアクション（チャンネルへのリノート等）。タイムラインへ
  /// 反映するものが無いので通知だけ。
  Future<void> runVoid(
    Future<void> Function() action,
    String successMessage,
  ) async {
    try {
      await action();
      _notifyCompleted();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e, st) {
      _report('runVoid', e, st, phase: 'post_action');
    }
  }

  /// リアクションの付与 / 取り消し。API が投稿を返さないので、成功後に
  /// [BackendAdapter.getPostById] で取り直してタイムラインへ反映する。
  ///
  /// [phase] は付与 (`reaction_add`) と取り消し (`reaction_remove`) で分ける
  /// (#924)。両方が `reaction_add` に畳まれると Sentry でどちらの失敗か混ざる。
  Future<void> runReaction(
    BackendAdapter adapter,
    String postId,
    Future<void> Function() action,
    String successMessage, {
    String phase = 'reaction_add',
  }) async {
    final timeline = _timeline;
    try {
      await action();
      final updated = await adapter.getPostById(postId);
      timeline.updatePost(updated);
      _notifyCompleted();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e, st) {
      _report('runReaction', e, st, phase: phase);
    }
  }

  /// ブースト / リノートの取り消し (#561)。
  ///
  /// ⚠ **Misskey と Mastodon で消す対象が違う。** Misskey は自分のリノート
  /// note 表示そのものを delete するので [outerPost]（タイムラインに並んでいる
  /// リノート行）を渡し、成功したらその行を消す。Mastodon は元 status の id で
  /// `/unreblog` するので [targetPost] を渡す。
  Future<void> unrepeat({
    required BackendAdapter adapter,
    required Post outerPost,
    required Post targetPost,
    required bool isOwnRenote,
    required String boostLabel,
  }) async {
    final timeline = _timeline;
    try {
      await adapter.unrepeatPost(isOwnRenote ? outerPost : targetPost);
      if (isOwnRenote) {
        timeline.removePost(outerPost.id);
      }
      if (targetPost.reblogged) {
        final updated = targetPost.copyWith(
          reblogged: false,
          reblogCount: targetPost.reblogCount > 0
              ? targetPost.reblogCount - 1
              : 0,
        );
        timeline.updatePost(updated);
      }
      _notifyCompleted();
      messenger.showSnackBar(SnackBar(content: Text('$boostLabelを取り消しました')));
    } catch (e, st) {
      _report('unrepeat', e, st, phase: 'post_action');
    }
  }

  /// 反映先の TL を決める (#990)。
  ///
  /// 呼び出し側が [timeline] を渡していればそれを使い、無ければその場で取りにいく。
  /// ⚠ **取れなくても投げない。** ここで投げると `action()` の手前で止まり、
  /// 操作が送信されないまま成功も失敗も出ずに消える（Sentry CAPSICUM-4N）。
  VisibleTimelineMutator get _timeline =>
      timeline ?? readVisibleTimelinesOrDetached(ref);

  /// 更新後の投稿を呼び出し側へ渡す。
  ///
  /// ⚠ **[_notifyCompleted] と同じ理由で本体の `try` から切り離す。** 渡ってくる
  /// のはタイルのローカル表示更新（多くは `setState`）で、応答が返る前に画面を
  /// 離れると dispose 済みの State に触れて投げる。本体の `try` の中で投げると
  /// **API は成功しているのに「失敗しました」**が出て、Sentry の `post_action`
  /// にも偽の失敗が 1 件乗る。
  void _notifyPostUpdated(Post updated) {
    try {
      onPostUpdated?.call(updated);
    } catch (e) {
      debugLogException('PostActionRunner onPostUpdated error', e);
    }
  }

  /// 成功後の後始末（スレッドの取り直し等）を呼ぶ。
  ///
  /// ⚠ **アクション本体の失敗と混ぜない。** 渡ってくるのは呼び出し側の再取得で、
  /// スレッド画面は `ref.invalidate` を渡している。応答が返る前に画面を離れると
  /// dispose 済みの `ref` に触れて投げるため、本体の `try` に直接置くと
  /// **API は成功しているのに「失敗しました」**が出て、Sentry の `post_action`
  /// にも偽の失敗が 1 件乗る。投票の導線 ([post_tile] の `_PollCard`) が同じ理由で
  /// 個別に包んでいたものを、集約したこちらでも同じ形にする。
  void _notifyCompleted() {
    try {
      onActionCompleted?.call();
    } catch (e) {
      debugLogException('PostActionRunner onActionCompleted error', e);
    }
  }

  /// 失敗の扱いを 1 箇所に閉じる。
  ///
  /// ⚠ **[phase] は「操作の種類」を表す軸で、導線は名乗らない。** v1.53 までは
  /// 導線名（`touch_action` 等）を出していたため、同じお気に入り / ブーストの
  /// 失敗が導線ごとに別系列へ散り、**どちらで絞っても母数にならない**状態だった。
  /// 規約は [describePostActionError] の doc が正本。
  void _report(String label, Object e, StackTrace st, {required String phase}) {
    debugLogException('PostActionRunner.$label failed', e);
    if (kDebugMode && e is DioException) {
      debugPrint('Response body: ${e.response?.data}');
    }
    unawaited(
      Sentry.captureException(
        e,
        stackTrace: st,
        withScope: (scope) => scope.setTag('phase', phase),
      ),
    );
    messenger.showSnackBar(SnackBar(content: Text(describePostActionError(e))));
  }
}

/// 選択中の投稿に対する操作を、デスクトップメニューの項目として組む (#943)。
///
/// #912 でスレッド画面にメニューを足したとき、リプライ / ブースト / お気に入り /
/// ブックマークは**外から開く口が無い**という理由で載せられなかった。実行側を
/// [PostActionRunner] へ、判定を [PostActionAvailability] へ寄せたので、ここは
/// 項目を並べるだけで済む。
///
/// [availability] が null は**未選択**（↑ ↓ でまだ辿っていない）。#835 の
/// 「使えない操作をメニューにだけ見せない」に従い、項目は残して無効化する。
/// 消す方を採らないのは #912 / #939 と同じ理由で、選択のたびに項目数が変わると
/// 場所が動いて探しにくいため。
///
/// ⚠ **お気に入り / ブックマークに取り消しを置いていないのは、シート
/// （`post_tile._showActionMenu`）にも無いから。** シートは追加のみで、
/// 取り消しはタッチ操作行 (`post_touch_action_row`) だけが持つ。ここで足すと
/// 「メニューからは外せるがシートからは外せない」という新しい非対称が生まれる
/// ので、揃えるならシートごと別途。ブーストだけ取り消しがあるのはシートに
/// 「$boostLabel を取り消す」があるため。
List<MenuEntry> buildPostActionMenuEntries({
  required String boostLabel,
  required String bookmarkLabel,
  required PostActionAvailability? availability,
  required VoidCallback onReply,
  required VoidCallback onQuote,
  required VoidCallback onBoost,
  required VoidCallback onUnboost,
  required VoidCallback onFavorite,
  required VoidCallback onBookmark,
}) {
  // 未選択なら全項目を無効。個別条件は選択があるときだけ見る。
  VoidCallback? enabledIf(bool condition, VoidCallback action) =>
      availability != null && condition ? action : null;

  return [
    MenuActionEntry(
      label: 'リプライ',
      icon: Icons.reply,
      onSelected: enabledIf(availability?.canReply ?? false, onReply),
    ),
    MenuActionEntry(
      label: '引用',
      icon: Icons.format_quote,
      onSelected: enabledIf(availability?.canQuote ?? false, onQuote),
    ),
    const MenuGroupSeparator(),
    MenuActionEntry(
      label: boostLabel,
      icon: Icons.repeat,
      onSelected: enabledIf(availability?.canBoost ?? false, onBoost),
    ),
    MenuActionEntry(
      label: '$boostLabelを取り消す',
      icon: Icons.repeat_on,
      onSelected: enabledIf(availability?.canUnrepeat ?? false, onUnboost),
    ),
    const MenuGroupSeparator(),
    MenuActionEntry(
      label: 'お気に入り',
      icon: Icons.star_outline,
      onSelected: enabledIf(availability?.canFavorite ?? false, onFavorite),
    ),
    MenuActionEntry(
      label: bookmarkLabel,
      icon: Icons.bookmark_outline,
      onSelected: enabledIf(availability?.canBookmark ?? false, onBookmark),
    ),
  ];
}

/// ある投稿に対して「いま何ができるか」(#943)。
///
/// 判定はアクションシート (`post_tile._showActionMenu`) が持っていたものを
/// そのまま写した。**シートとメニューバーで条件が割れないよう**、両方がここを
/// 通る（#835 の「使えない操作をメニューにだけ見せない」は、条件が 2 か所に
/// 分かれていると守りようがない）。
@immutable
class PostActionAvailability {
  const PostActionAvailability({
    required this.outerPost,
    required this.targetPost,
    required this.isOwn,
    required this.isOwnRenote,
    required this.canUnrepeat,
    required this.canBoost,
    required this.canReply,
    required this.canQuote,
    required this.canFavorite,
    required this.canBookmark,
    required this.canReact,
    required this.boostLabel,
    required this.bookmarkLabel,
  });

  /// [post] に対する判定を組む。[post] はタイムラインに並んでいる行そのもの
  /// （ブーストなら「誰かがブーストした」の外側）。
  factory PostActionAvailability.of(WidgetRef ref, Post post) {
    final adapter = ref.read(currentAdapterProvider);
    final currentUser = ref.read(currentAccountProvider)?.user;
    final targetPost = post.reblog ?? post;
    final isOwn = currentUser != null && targetPost.author.id == currentUser.id;
    final isOwnRenote =
        post.reblog != null &&
        currentUser != null &&
        post.author.id == currentUser.id;
    // ブーストは公開 / ひかえめな公開のみ。シートの出し分けと同じ条件。
    final boostable =
        targetPost.scope == PostScope.public ||
        targetPost.scope == PostScope.unlisted;
    return PostActionAvailability(
      outerPost: post,
      targetPost: targetPost,
      isOwn: isOwn,
      isOwnRenote: isOwnRenote,
      canUnrepeat: isOwnRenote || targetPost.reblogged,
      canBoost: adapter != null && boostable,
      canReply: adapter != null,
      canQuote: adapter != null && targetPost.quotable,
      canFavorite: adapter is FavoriteSupport,
      canBookmark: adapter is BookmarkSupport,
      canReact: adapter is ReactionSupport,
      boostLabel: ref.read(reblogLabelProvider),
      // Misskey の「お気に入り」は意味的にブックマーク相当（docs/CLAUDE.md の
      // 機能マッピング）。ラベルだけ ReactionSupport の有無で切り替える。
      bookmarkLabel: adapter is ReactionSupport ? 'お気に入り' : 'ブックマーク',
    );
  }

  /// タイムラインに並んでいる行（ブーストなら外側）。
  final Post outerPost;

  /// 実際に操作する対象（ブーストなら中身）。
  final Post targetPost;

  final bool isOwn;
  final bool isOwnRenote;
  final bool canUnrepeat;
  final bool canBoost;
  final bool canReply;
  final bool canQuote;
  final bool canFavorite;
  final bool canBookmark;
  final bool canReact;

  /// 「ブースト」/「リノート」。サーバー種別で変わる。
  final String boostLabel;

  /// 「ブックマーク」/「お気に入り」。
  final String bookmarkLabel;
}
