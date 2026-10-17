import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

import '../util/filter_labels.dart';

/// フィルター / ワードミュートで畳んだ投稿の代わりに出す 1 行 (#1293)。
///
/// 投稿（`PostTile`）・通知（`NotificationTile`）・「すべての通知」の 3 か所が
/// 同じ形を丸写ししていたのを寄せた。文言は [filterNoticeLabel] が決める。
class FilterNoticeRow extends StatelessWidget {
  const FilterNoticeRow({super.key, required this.verdict, this.trailing});

  final FilterVerdict verdict;

  /// 右端に置くもの（投稿の「表示する」など）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      children: [
        Icon(Icons.filter_alt_outlined, size: 16, color: style?.color),
        const SizedBox(width: 8),
        Expanded(child: Text(filterNoticeLabel(verdict), style: style)),
        ?trailing,
      ],
    );
  }
}
