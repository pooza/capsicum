import 'dart:ui';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/misskey_api_error.dart';
import '../../util/oauth_scope_error.dart';
import '../util/notification_type_display.dart'
    show contentWarningFallbackLabel;
import '../util/provider_scope_carrier.dart';
import '../util/sensitive_media.dart';
import '../widget/bottom_safe_area.dart';

class GalleryDetailScreen extends StatelessWidget {
  final GalleryPost post;

  /// デッキのカラムの中身として描く (#1150)。戻るボタンを出さない（投稿の
  /// タイトルを出すので AppBar は残す）。
  final bool embedded;

  const GalleryDetailScreen({
    super.key,
    required this.post,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !embedded,
        title: Text(post.title),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: ListView(
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
                      // いいね (#1053)。⚠ いつも押せる。自分の投稿かは
                      // サーバーの `YOUR_POST` で知る（手元では見分けない）。
                      _GalleryLikeButton(post: post),
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
      ),
    );
  }

  Widget _buildImage(BuildContext context, Attachment file, int index) {
    final isSensitive = post.isSensitive;

    return GestureDetector(
      onTap: () {
        context.push(
          '/media',
          extra: extraWithProviderScope(context, {
            'attachments': post.files,
            'initialIndex': index,
          }),
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
                        filter: ImageFilter.blur(
                          sigmaX: kSensitiveMediaBlurSigma,
                          sigmaY: kSensitiveMediaBlurSigma,
                        ),
                        child: Container(color: Colors.black.withAlpha(30)),
                      ),
                    ),
                    const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.visibility_off, color: Colors.white),
                        SizedBox(height: 4),
                        Text(
                          contentWarningFallbackLabel,
                          style: TextStyle(color: Colors.white),
                        ),
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

/// ギャラリーの投稿のいいね (#1053)。Play のいいね（`flash_view_screen.dart` の
/// `_toggleLike`）と同じ形:
///
/// - 押したらすぐ見た目を変え（楽観更新）、失敗したら戻す
/// - `ALREADY_LIKED` / `NOT_LIKED` は、サーバーの状態と揃っただけなので成功扱い
/// - 自分の投稿（`YOUR_POST`）は専用の文言で知らせる
/// - 旧トークン（`write:gallery-likes` が無い）の 403 は、再ログインを案内する。
///   失敗ではないので Sentry へ送らない
class _GalleryLikeButton extends ConsumerStatefulWidget {
  const _GalleryLikeButton({required this.post});

  final GalleryPost post;

  @override
  ConsumerState<_GalleryLikeButton> createState() => _GalleryLikeButtonState();
}

class _GalleryLikeButtonState extends ConsumerState<_GalleryLikeButton> {
  late bool _isLiked = widget.post.isLiked ?? false;
  late int _likedCount = widget.post.likedCount;
  bool _toggling = false;

  Future<void> _toggle() async {
    if (_toggling) return;
    final raw = ref.read(currentAdapterProvider);
    if (raw is! GallerySupport) return;
    final gallery = raw as GallerySupport;
    final account = ref.accountForReport;

    final wasLiked = _isLiked;
    setState(() {
      _toggling = true;
      _isLiked = !wasLiked;
      _likedCount += wasLiked ? -1 : 1;
    });
    try {
      if (wasLiked) {
        await gallery.unlikeGalleryPost(widget.post.id);
      } else {
        await gallery.likeGalleryPost(widget.post.id);
      }
    } catch (e, st) {
      final code = misskeyApiErrorCode(e);
      if ((!wasLiked && code == 'ALREADY_LIKED') ||
          (wasLiked && code == 'NOT_LIKED')) {
        return;
      }
      if (!mounted) return;
      setState(() {
        _isLiked = wasLiked;
        _likedCount += wasLiked ? 1 : -1;
      });
      final messenger = ScaffoldMessenger.of(context);
      if (code == 'YOUR_POST') {
        messenger.showSnackBar(
          const SnackBar(content: Text('自分のギャラリー投稿にはいいねできません')),
        );
        return;
      }
      if (isOAuthScopeError(e)) {
        messenger.showSnackBar(
          const SnackBar(content: Text(oauthScopeErrorMessage)),
        );
        return;
      }
      reportOpFailure(
        tagKey: 'gallery.op',
        operation: wasLiked ? 'unlike' : 'like',
        error: e,
        stackTrace: st,
        account: account,
      );
      messenger.showSnackBar(const SnackBar(content: Text('いいねの更新に失敗しました')));
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextButton.icon(
      key: const ValueKey('gallery-like'),
      onPressed: _toggling ? null : _toggle,
      icon: Icon(
        _isLiked ? Icons.favorite : Icons.favorite_border,
        size: 18,
        // ⚠ 色は Play のいいね（`flash_view_screen.dart`）とそろえる。
        color: _isLiked ? theme.colorScheme.primary : null,
      ),
      label: Text('$_likedCount'),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
    );
  }
}
