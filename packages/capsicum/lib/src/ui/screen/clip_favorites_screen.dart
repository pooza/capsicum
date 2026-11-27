import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/clip_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

/// お気に入りに入れたクリップ (#1377)。入口はクリップのクイックチューザの奥
/// （#805 の基準・クリップと同じ場所）。
///
/// ほかの人のクリップなので、誰のクリップかを添える。
class ClipFavoritesScreen extends ConsumerWidget {
  const ClipFavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clips = ref.watch(favoriteClipsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('お気に入りのクリップ')),
      body: BottomSafeArea(
        child: clips.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => RetryErrorView(
            // ⚠ 旧トークン（`read:clip-favorite` が無い）は再ログインを案内する。
            message: isOAuthScopeError(e)
                ? oauthScopeErrorMessage
                : '読み込みに失敗しました',
            isRetrying: clips.isLoading,
            onRetry: () => ref.invalidate(favoriteClipsProvider),
          ),
          data: (list) {
            if (list.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'お気に入りのクリップはありません。'
                    'ほかの人のクリップを開いて、☆ から入れられます。',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: () => ref.refresh(favoriteClipsProvider.future),
              child: ListView(
                children: [
                  for (final clip in list) _FavoriteClipTile(clip: clip),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FavoriteClipTile extends StatelessWidget {
  const _FavoriteClipTile({required this.clip});

  final NoteClip clip;

  @override
  Widget build(BuildContext context) {
    final owner = clip.ownerName;
    final description = clip.description;
    final sub = [
      ?owner,
      if (description != null && description.isNotEmpty) description,
    ].join(' · ');
    return ListTile(
      key: ValueKey('favorite-clip-${clip.id}'),
      leading: const Icon(Icons.star_outline),
      title: Text(clip.name),
      subtitle: sub.isEmpty
          ? null
          : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => context.push('/clip/${clip.id}', extra: clip),
    );
  }
}
