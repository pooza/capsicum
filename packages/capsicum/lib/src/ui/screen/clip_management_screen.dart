import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/clip_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/clip_actions_sheet.dart';
import '../widget/retry_error_view.dart';

/// クリップを管理する画面 (#1050)。
///
/// ドロワーのクイックチューザ（`showClipList`）の奥に置く。型はアンテナ
/// （#1052・`antenna_management_screen.dart`）と同じ。
class ClipManagementScreen extends ConsumerWidget {
  const ClipManagementScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final saved = await context.push<Object?>('/clips/edit');
    if (saved != null) ref.invalidate(clipsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clips = ref.watch(clipsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('クリップ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新規作成',
            onPressed: () => _create(context, ref),
          ),
        ],
      ),
      body: BottomSafeArea(
        child: clips.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => RetryErrorView(
            message: isOAuthScopeError(e)
                ? oauthScopeErrorMessage
                : '読み込みに失敗しました\n${summarizeOpError(e)}',
            isRetrying: clips.isLoading,
            onRetry: () => ref.invalidate(clipsProvider),
          ),
          data: (list) {
            if (list.isEmpty) {
              return const Center(child: Text('クリップはありません\n右上の ＋ から作れます'));
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final clip = list[index];
                final description = clip.description;
                return ListTile(
                  leading: Icon(clipVisibilityIcon(clip)),
                  title: Text(
                    clip.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: description == null || description.isEmpty
                      ? null
                      : Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  onTap: () => context.push('/clip/${clip.id}', extra: clip),
                  trailing: IconButton(
                    icon: const Icon(Icons.more_horiz),
                    tooltip: 'クリップの操作',
                    onPressed: () => showClipActions(context, ref, clip),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
