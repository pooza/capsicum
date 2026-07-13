import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/announcement_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../service/tco_resolver.dart';
import '../../url_helper.dart';
import 'content_parser.dart';
import 'emoji_picker.dart';

class AnnouncementTile extends ConsumerStatefulWidget {
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
  ConsumerState<AnnouncementTile> createState() => _AnnouncementTileState();
}

class _AnnouncementTileState extends ConsumerState<AnnouncementTile> {
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
      emojiSize: ref.watch(emojiSizeProvider),
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
            _buildReactions(context, theme),
          ],
        ),
      ),
    );
  }

  /// お知らせのリアクション行 (#819)。リアクション対応アダプタ（Mastodon）でのみ
  /// 表示する。既存チップはタップで付け外し、末尾の「+」で絵文字ピッカーを開く。
  Widget _buildReactions(BuildContext context, ThemeData theme) {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter is! AnnouncementReactionSupport) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final r in announcement.reactions)
            _AnnouncementReactionChip(
              reaction: r,
              onTap: () => _toggle(r.name, add: !r.me),
            ),
          _AddReactionButton(onTap: () => _openReactionPicker(context)),
        ],
      ),
    );
  }

  Future<void> _toggle(String name, {required bool add}) async {
    try {
      await ref
          .read(announcementProvider.notifier)
          .toggleReaction(announcement.id, name, add: add);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('リアクションを更新できませんでした')));
      }
    }
  }

  void _openReactionPicker(BuildContext context) {
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    if (account == null || adapter is! AnnouncementReactionSupport) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final screenHeight = MediaQuery.of(context).size.height;
        final keyboardInset = MediaQuery.of(sheetContext).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: SizedBox(
            height: (screenHeight - keyboardInset) * 0.5,
            child: EmojiPicker(
              adapter: adapter as BackendAdapter,
              host: account.key.host,
              mulukhiya: account.mulukhiya,
              accessToken: account.userSecret.accessToken,
              forReaction: true,
              onSelected: (emoji) {
                Navigator.pop(sheetContext);
                // ピッカーはカスタム絵文字を `:shortcode:`、Unicode は素の文字で
                // 返す。Mastodon の reaction API はコロン無し shortcode を要求
                // するため剥がす。
                final name = emoji.startsWith(':') && emoji.endsWith(':')
                    ? emoji.substring(1, emoji.length - 1)
                    : emoji;
                _toggle(name, add: true);
              },
            ),
          ),
        );
      },
    );
  }
}

/// お知らせのリアクションチップ (#819)。カスタム絵文字は [AnnouncementReaction.url]
/// を画像表示し、無ければ素のテキスト（Unicode 絵文字 / 未 reconcile の shortcode）。
class _AnnouncementReactionChip extends StatelessWidget {
  final AnnouncementReaction reaction;
  final VoidCallback onTap;

  const _AnnouncementReactionChip({
    required this.reaction,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMine = reaction.me;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isMine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isMine ? scheme.primary : scheme.outlineVariant,
            width: isMine ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reaction.url != null)
              Image.network(
                reaction.url!,
                height: 18,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Text(reaction.name),
              )
            else
              Text(reaction.name, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 4),
            Text(
              '${reaction.count}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isMine ? scheme.onPrimaryContainer : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddReactionButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AddReactionButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Icon(
          Icons.add_reaction_outlined,
          size: 18,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
