import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

class AnnouncementTile extends StatelessWidget {
  final Announcement announcement;
  final VoidCallback? onDismiss;

  const AnnouncementTile({
    super.key,
    required this.announcement,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = announcement.publishedAt;
    final dateStr = '${d.year}/${d.month}/${d.day}';

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
                if (!announcement.read && onDismiss != null)
                  TextButton(onPressed: onDismiss, child: const Text('既読にする')),
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
            Text(
              announcement.content,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: announcement.read ? theme.colorScheme.outline : null,
              ),
            ),
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
