import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

import '../../service/tco_resolver.dart';
import '../../url_helper.dart';
import 'content_parser.dart';

class AnnouncementTile extends StatefulWidget {
  final Announcement announcement;
  final String? host;
  final VoidCallback? onDismiss;

  const AnnouncementTile({
    super.key,
    required this.announcement,
    this.host,
    this.onDismiss,
  });

  @override
  State<AnnouncementTile> createState() => _AnnouncementTileState();
}

class _AnnouncementTileState extends State<AnnouncementTile> {
  ContentRenderer? _contentRenderer;

  Announcement get announcement => widget.announcement;

  static final _tcoPattern = RegExp(r'https?://t\.co/\S+');

  @override
  void initState() {
    super.initState();
    _resolveTcoUrls();
  }

  void _resolveTcoUrls() {
    final content = announcement.content;
    for (final match in _tcoPattern.allMatches(content)) {
      final url = match.group(0)!;
      if (TcoResolver.getCached(url) != null) continue;
      TcoResolver.resolve(url).then((resolved) {
        if (resolved != null && mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _contentRenderer?.dispose();
    super.dispose();
  }

  TextSpan _renderContent(String content, TextStyle baseStyle) {
    _contentRenderer?.dispose();
    _contentRenderer = ContentRenderer(
      baseStyle: baseStyle,
      resolveEmoji: (shortcode) {
        if (widget.host != null) {
          return 'https://${widget.host}/emoji/$shortcode.webp';
        }
        return null;
      },
      resolveUrl: (url) =>
          TcoResolver.isTcoUrl(url) ? TcoResolver.getCached(url) : null,
      onLinkTap: (url) {
        final uri = Uri.tryParse(url);
        if (uri != null) launchUrlSafely(uri);
      },
    );
    return announcement.isHtml
        ? _contentRenderer!.renderHtml(content)
        : _contentRenderer!.renderMfm(content);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = announcement.publishedAt;
    final dateStr = '${d.year}/${d.month}/${d.day}';
    final baseStyle =
        theme.textTheme.bodyMedium?.copyWith(
          color: announcement.read ? theme.colorScheme.outline : null,
        ) ??
        const TextStyle();

    return Container(
      color: announcement.read
          ? null
          : theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.campaign,
                  size: 20,
                  color: announcement.read
                      ? theme.colorScheme.outline
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dateStr,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
                if (!announcement.read && widget.onDismiss != null)
                  TextButton(
                    onPressed: widget.onDismiss,
                    child: const Text('既読にする'),
                  ),
              ],
            ),
            if (announcement.title != null) ...[
              const SizedBox(height: 4),
              Text(
                announcement.title!,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: announcement.read
                      ? FontWeight.normal
                      : FontWeight.bold,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text.rich(_renderContent(announcement.content, baseStyle)),
            if (announcement.imageUrl != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  announcement.imageUrl!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
