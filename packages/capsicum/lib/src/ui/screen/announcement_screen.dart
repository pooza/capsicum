import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/announcement_provider.dart';
import '../widget/announcement_tile.dart';

class AnnouncementScreen extends ConsumerWidget {
  const AnnouncementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcements = ref.watch(announcementProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('お知らせ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: announcements.when(
        data: (state) => state.announcements.isEmpty
            ? const Center(child: Text('お知らせはありません'))
            : RefreshIndicator(
                onRefresh: () =>
                    ref.refresh(announcementProvider.future),
                child: ListView.separated(
                  itemCount: state.announcements.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final announcement = state.announcements[index];
                    return AnnouncementTile(
                      announcement: announcement,
                      onDismiss: announcement.read
                          ? null
                          : () => ref
                              .read(announcementProvider.notifier)
                              .dismiss(announcement.id),
                    );
                  },
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'お知らせの読み込みに失敗しました\n$error',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(announcementProvider),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
