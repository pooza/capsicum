import 'package:capsicum_core/capsicum_core.dart';
// capsicum_core の `Page` と Flutter の `Page` (Navigator) が衝突するため
// Flutter 側を hide する。本 widget は Misskey ページのみ扱う。
import 'package:flutter/material.dart' hide Page;

import '../screen/page_view_screen.dart';

/// Misskey ページ (#186) の一覧表示用カード。
///
/// プロフィール画面の「ページ」タブと「いいねしたページ」画面で同じ見た目を
/// 共有するため抽出。タップで [PageViewScreen] へ遷移する。
class PageCard extends StatelessWidget {
  final Page page;

  const PageCard({super.key, required this.page});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = page.eyeCatchingImage?.url;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PageViewScreen(initialPage: page),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (thumbnail != null && thumbnail.isNotEmpty)
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    thumbnail,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Center(child: Icon(Icons.broken_image)),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      page.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (page.summary != null && page.summary!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        page.summary!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
