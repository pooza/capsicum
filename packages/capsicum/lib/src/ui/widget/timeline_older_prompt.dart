import 'package:flutter/material.dart';

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
  });

  /// 続きを取得している最中か。
  final bool isLoading;

  final VoidCallback onLoadOlder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('絞り込みで多くの投稿が除外されています', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (isLoading)
            const CircularProgressIndicator()
          else
            FilledButton.tonal(
              onPressed: onLoadOlder,
              child: const Text('さらに古い投稿を探す'),
            ),
        ],
      ),
    );
  }
}
