import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

/// プロフィールで紹介しているハッシュタグ (#1075)。
///
/// 見出しは WebUI の「プロフィールで紹介する」（`hashtag.feature`）に合わせた。
/// 並びはサーバーが返した順（本人が選んだ順）のまま。タップの動作は呼び出し側が
/// 決める（プロフィール画面は本文中のタグと同じメニューを出す）。
class FeaturedTagsSection extends StatelessWidget {
  const FeaturedTagsSection({
    super.key,
    required this.tags,
    required this.onTap,
    this.onEdit,
  });

  final List<FeaturedTag> tags;
  final void Function(FeaturedTag tag) onTap;

  /// 自分のプロフィールのときだけ渡す。見出しの右に編集ボタンを出す。
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Row(
            children: [
              Icon(Icons.tag, size: 14, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                '紹介しているハッシュタグ',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (onEdit != null) ...[
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.edit, size: 16),
                  tooltip: '紹介するハッシュタグを編集',
                  visualDensity: VisualDensity.compact,
                  onPressed: onEdit,
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in tags)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    tag.statusesCount > 0
                        ? '#${tag.name}  ${tag.statusesCount}'
                        : '#${tag.name}',
                  ),
                  tooltip: _tooltip(tag),
                  onPressed: () => onTap(tag),
                ),
            ],
          ),
        ),
        const Divider(height: 8, thickness: 4),
      ],
    );
  }

  /// 件数と最後の投稿日（WebUI の「N 件の投稿・最終投稿 日付」相当）。
  static String _tooltip(FeaturedTag tag) {
    final last = tag.lastStatusAt;
    final count = '${tag.statusesCount} 件の投稿';
    if (last == null) return count;
    final date =
        '${last.year}/${last.month.toString().padLeft(2, '0')}/'
        '${last.day.toString().padLeft(2, '0')}';
    return '$count・最終投稿 $date';
  }
}
