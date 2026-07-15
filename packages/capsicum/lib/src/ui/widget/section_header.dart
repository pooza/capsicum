import 'package:flutter/material.dart';

/// 設定・サーバー情報・コレクション詳細などで使う共通のセクション見出し（#804）。
///
/// 一段濃い地（`surfaceContainerHighest`）で帯状に塗り、項目行と明確に分離して
/// 視認性を上げる。素の `titleMedium` テキストや画面ごとの独自見出しに散らばって
/// いたスタイルをこれに統一する。
class SectionHeader extends StatelessWidget {
  final String title;

  const SectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
