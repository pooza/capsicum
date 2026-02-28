import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

class PostTile extends StatelessWidget {
  final Post post;

  const PostTile({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final displayPost = post.reblog ?? post;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundImage:
                displayPost.author.avatarUrl != null
                    ? NetworkImage(displayPost.author.avatarUrl!)
                    : null,
            child:
                displayPost.author.avatarUrl == null
                    ? Text(
                      displayPost.author.username[0].toUpperCase(),
                    )
                    : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (post.reblog != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${post.author.displayName ?? post.author.username} がブースト',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Text(
                  displayPost.author.displayName ??
                      displayPost.author.username,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  _stripHtml(displayPost.content ?? ''),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Minimal HTML tag stripping for display.
  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '');
  }
}
