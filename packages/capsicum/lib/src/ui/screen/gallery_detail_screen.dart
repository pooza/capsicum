import 'dart:ui';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class GalleryDetailScreen extends StatelessWidget {
  final GalleryPost post;

  const GalleryDetailScreen({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(post.title),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          // Images
          for (var i = 0; i < post.files.length; i++)
            _buildImage(context, post.files[i], i),
          // Metadata
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(post.title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (post.author.avatarUrl != null) ...[
                      CircleAvatar(
                        radius: 14,
                        backgroundImage: NetworkImage(post.author.avatarUrl!),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        post.author.displayName ?? post.author.username,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (post.likedCount > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.favorite,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${post.likedCount}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                  ],
                ),
                if (post.description != null &&
                    post.description!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(post.description!, style: theme.textTheme.bodyMedium),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImage(BuildContext context, Attachment file, int index) {
    final isSensitive = post.isSensitive;

    return GestureDetector(
      onTap: () {
        context.push(
          '/media',
          extra: {'attachments': post.files, 'initialIndex': index},
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: isSensitive
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    Image.network(
                      file.previewUrl ?? file.url,
                      fit: BoxFit.cover,
                      width: double.infinity,
                    ),
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                        child: Container(color: Colors.black.withAlpha(30)),
                      ),
                    ),
                    const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.visibility_off, color: Colors.white),
                        SizedBox(height: 4),
                        Text('閲覧注意', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ],
                )
              : Image.network(
                  file.previewUrl ?? file.url,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  errorBuilder: (_, _, _) => Container(
                    height: 200,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: const Center(child: Icon(Icons.broken_image)),
                  ),
                ),
        ),
      ),
    );
  }
}
