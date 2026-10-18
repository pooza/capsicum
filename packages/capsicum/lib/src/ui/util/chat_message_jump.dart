import 'dart:async';

import 'package:flutter/material.dart';

import '../../provider/chat_provider.dart';

/// 検索で選んだメッセージまで遡るとき、続きを引く上限（1 ページ 30 件）(#1188)。
///
/// ⚠ 上限を置くのは、古いメッセージを選んだときに何十ページも引き続けないため。
/// 届かなければ「遡れなかった」と知らせる。
const kChatJumpMaxPages = 20;

/// 進行中の続き読みを待つ間隔と上限（v2.4 リリース前レビュー）。上限は、続き読みの
/// 再試行の待ちを含めても足りる長さ。
const _kChatJumpWaitStep = Duration(milliseconds: 100);
const _kChatJumpWaitLimit = Duration(seconds: 30);

/// 選んだメッセージに色を付けておく時間 (#1188)。
const kChatJumpHighlight = Duration(seconds: 2);

/// チャットの一覧（新しい順の逆向き `ListView`）で、検索で選んだメッセージの
/// 位置へ移る (#1188)。DM のスレッドとルームの画面で共有する。
///
/// 1. 対象が一覧に入るまで、古い側へ続きを引く（[kChatJumpMaxPages] まで）
/// 2. 対象の吹き出しが組み立てられるまで古い側へ送る（一覧は高さが決まって
///    いないので、添字では送れない）。組み立てられたら真ん中へ寄せる
/// 3. しばらく色を付ける（どれを選んだかを見失わないため）
///
/// 一覧の側は、各メッセージを [wrapForJump] で包む。
mixin ChatMessageJump<T extends StatefulWidget> on State<T> {
  final _jumpKey = GlobalKey();
  String? _highlightedId;
  Timer? _highlightTimer;

  /// 一覧の各メッセージを包む。対象なら鍵と色を付ける。
  Widget wrapForJump(String messageId, Widget child) {
    if (messageId != _highlightedId) return child;
    return KeyedSubtree(
      key: _jumpKey,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.primaryContainer.withAlpha(120),
        child: child,
      ),
    );
  }

  void disposeChatJump() => _highlightTimer?.cancel();

  /// [id] のメッセージへ移る。届かなかったら false。
  Future<bool> jumpToMessage({
    required String id,
    required ScrollController controller,
    required ChatThreadState? Function() read,
    required Future<void> Function() loadMore,
  }) async {
    var page = 0;
    var waited = Duration.zero;
    while (true) {
      final state = read();
      if (state == null) return false;
      if (state.messages.any((m) => m.id == id)) break;
      if (page >= kChatJumpMaxPages ||
          !state.hasMore ||
          state.loadMoreError != null) {
        return false;
      }
      // ⚠ 続き読みの途中（スクロールで走ったもの・再試行の待ち）は、終わるまで
      // 待つ（v2.4 リリース前レビュー）。`loadMore` は進行中だと何もせずに返る
      // ので、そのまま回すと一覧が伸びないまま上限を使い切り、届くメッセージでも
      // 「遡れなかった」になる。⚠ 待つ時間にも上限を置く。
      if (state.isLoadingMore) {
        if (waited >= _kChatJumpWaitLimit) return false;
        await Future<void>.delayed(_kChatJumpWaitStep);
        waited += _kChatJumpWaitStep;
        if (!mounted) return false;
        continue;
      }
      await loadMore();
      page++;
      if (!mounted) return false;
    }

    _highlightTimer?.cancel();
    setState(() => _highlightedId = id);
    await WidgetsBinding.instance.endOfFrame;

    // 対象が組み立てられるまで、古い側（逆向きの一覧では pixels が増える側）へ
    // 送る。⚠ 端まで来て動かなくなったら打ち切る。
    for (var step = 0; step < 200 && _jumpKey.currentContext == null; step++) {
      if (!mounted || !controller.hasClients) return false;
      final position = controller.position;
      final next = (position.pixels + position.viewportDimension * 0.8).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next == position.pixels) break;
      controller.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
    final target = _jumpKey.currentContext;
    if (target == null || !mounted || !target.mounted) return false;
    await Scrollable.ensureVisible(
      target,
      alignment: 0.5,
      duration: const Duration(milliseconds: 200),
    );
    _highlightTimer = Timer(kChatJumpHighlight, () {
      if (mounted) setState(() => _highlightedId = null);
    });
    return true;
  }
}
