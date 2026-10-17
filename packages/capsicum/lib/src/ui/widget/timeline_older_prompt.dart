import 'package:flutter/material.dart';

import '../../provider/timeline_provider.dart';

/// 一覧の末尾に「さらに古い投稿を探す」を出すか (#1292)。
///
/// 続き読みが上限まで引いても見える投稿を 1 件も足せなかった（`pageCapHit`）が、
/// サーバーにはまだ続きがある。⚠ 何も足されないと一覧の長さが変わらないので、
/// 末尾への到達という続き読みの合図が来ない（Android では末尾で引っ張っても
/// スクロールの通知が出ない）。手で先へ進める入口を出す。
///
/// ⚠ 一覧が空のときは各画面の空表示のほうで扱う（#1283）。
bool olderStalled(TimelineState state) =>
    state.pageCapHit &&
    state.hasMore &&
    !state.isLoadingMore &&
    state.posts.isNotEmpty;

/// 一覧の末尾に 1 行足すか（続きの読み込み中のスピナーか、[olderStalled] の
/// 入口）(#1293)。`itemCount` に足す数。
///
/// ⚠ リスト / チャンネル / ハッシュタグ / 通知の 4 画面が同じ組み立てを
/// 丸写ししていた（コメントの文面まで同一）。ここと [TimelineOlderTail] /
/// [TimelineEmptyOrOlder] に寄せた。
int olderTailCount({required bool isLoadingMore, required bool stalled}) =>
    isLoadingMore || stalled ? 1 : 0;

/// 一覧の末尾の 1 行。読み込み中ならスピナー、そうでなければ手で先を引く入口
/// （上限まで引いても見える投稿が出なかったとき・#1292）(#1293)。
class TimelineOlderTail extends StatelessWidget {
  const TimelineOlderTail({
    super.key,
    required this.isLoadingMore,
    required this.onLoadOlder,
    this.message = kOlderPromptMessage,
    this.actionLabel = kOlderPromptAction,
  });

  final bool isLoadingMore;
  final VoidCallback onLoadOlder;
  final String message;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    if (isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return TimelineOlderPrompt(
      isLoading: false,
      onLoadOlder: onLoadOlder,
      message: message,
      actionLabel: actionLabel,
    );
  }
}

/// 空の一覧の表示 (#1293)。続きがあれば手で先を引ける入口、無ければ
/// [emptyText]（#1283・空の一覧はスクロールできないので、続き読みの合図が来ない）。
class TimelineEmptyOrOlder extends StatelessWidget {
  const TimelineEmptyOrOlder({
    super.key,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadOlder,
    this.emptyText = '投稿がありません',
    this.message = kOlderPromptMessage,
    this.actionLabel = kOlderPromptAction,
  });

  final bool hasMore;
  final bool isLoadingMore;
  final VoidCallback onLoadOlder;
  final String emptyText;
  final String message;
  final String actionLabel;

  @override
  Widget build(BuildContext context) => Center(
    child: hasMore
        ? TimelineOlderPrompt(
            isLoading: isLoadingMore,
            onLoadOlder: onLoadOlder,
            message: message,
            actionLabel: actionLabel,
          )
        : Text(emptyText),
  );
}

/// 入口の既定の文言（投稿の一覧）。通知の一覧は「通知」と言い換えて渡す。
const kOlderPromptMessage = '絞り込みで多くの投稿が除外されています';
const kOlderPromptAction = 'さらに古い投稿を探す';

/// 絞り込みで何も足せなかったが、サーバーには続きがあるときに出す入口
/// (#1283 / #1292)。空の一覧なら空表示の代わりに、そうでなければ一覧の末尾に出す。
/// TL のほか、通知・プロフィールでも [message] / [actionLabel] を替えて使う。
///
/// 絞り込み（タグ TL の「含まない」・実況フィルタ）で先頭の数ページが丸ごと
/// 落ちると、一覧は空のままになる。空の一覧はスクロールできないので、続きを
/// 読む合図（末尾への到達）が二度と来ない。ここから手で先を引けるようにする。
class TimelineOlderPrompt extends StatelessWidget {
  const TimelineOlderPrompt({
    super.key,
    required this.isLoading,
    required this.onLoadOlder,
    this.message = kOlderPromptMessage,
    this.actionLabel = kOlderPromptAction,
  });

  /// 続きを取得している最中か。
  final bool isLoading;

  final VoidCallback onLoadOlder;

  /// 入口の説明と、ボタンの文言（通知の一覧では「通知」と言い換える）。
  final String message;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (isLoading)
            const CircularProgressIndicator()
          else
            FilledButton.tonal(
              onPressed: onLoadOlder,
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }
}
