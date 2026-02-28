import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/timeline_provider.dart';
import '../widget/post_tile.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    final timeline = ref.watch(homeTimelineProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('@${account?.user.username ?? ""}'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: timeline.when(
        data: (posts) => RefreshIndicator(
          onRefresh: () => ref.refresh(homeTimelineProvider.future),
          child: ListView.separated(
            itemCount: posts.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => PostTile(post: posts[index]),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'タイムラインの読み込みに失敗しました\n$error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
