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

/// 表示できる投稿が 1 件も無いが、サーバーには続きがある TL に出す入口 (#1283)。
///
/// 絞り込み（タグ TL の「含まない」・実況フィルタ）で先頭の数ページが丸ごと
/// 落ちると、一覧は空のままになる。空の一覧はスクロールできないので、続きを
/// 読む合図（末尾への到達）が二度と来ない。ここから手で先を引けるようにする。
class TimelineOlderPrompt extends StatelessWidget {
  const TimelineOlderPrompt({
    super.key,
    required this.isLoading,
    required this.onLoadOlder,
    this.message = '絞り込みで多くの投稿が除外されています',
    this.actionLabel = 'さらに古い投稿を探す',
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
