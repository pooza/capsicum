import 'package:flutter/material.dart';

/// 設定・サーバー情報・コレクション詳細などで使う共通のセクション見出し（#804）。
///
/// 一段濃い地（`surfaceContainerHighest`）で帯状に塗り、項目行と明確に分離して
/// 視認性を上げる。素の `titleMedium` テキストや画面ごとの独自見出しに散らばって
/// いたスタイルをこれに統一する。
///
/// **適用範囲は「同一画面内で項目リストを区切る節見出し」**（#846）。sliver 文脈
/// でも `SliverToBoxAdapter` に載せてそのまま使える（pages_screen が例）。帯を
/// 全幅で見せるため、横 padding のある `SliverPadding` の中には入れない。
///
/// **ボトムシートのタイトルには使わない**。`home_screen` のクイックチューザ
/// （「リスト」「リンク」等）の見出しは、節を区切るものではなくシート自体の題名
/// なので `titleMedium` のまま残している。ここに帯を敷くとシート先頭が窓の
/// ヘッダーのように見え、1 枚のシートを 2 段に割ったような誤読を招く。
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
