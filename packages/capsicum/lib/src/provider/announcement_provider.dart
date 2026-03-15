import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';

/// Announcement list state.
class AnnouncementState {
  final List<Announcement> announcements;

  const AnnouncementState({this.announcements = const []});

  AnnouncementState copyWith({List<Announcement>? announcements}) =>
      AnnouncementState(announcements: announcements ?? this.announcements);
}

/// Notifier that manages announcement fetching and dismissal.
class AnnouncementNotifier extends AutoDisposeAsyncNotifier<AnnouncementState> {
  @override
  Future<AnnouncementState> build() async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! AnnouncementSupport) {
      return const AnnouncementState();
    }

    final announcements = await (adapter as AnnouncementSupport)
        .getAnnouncements();

    return AnnouncementState(announcements: announcements);
  }

  /// Mark an announcement as read.
  Future<void> dismiss(String id) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! AnnouncementSupport) return;

    await (adapter as AnnouncementSupport).dismissAnnouncement(id);

    final current = state.valueOrNull;
    if (current == null) return;

    final updated = current.announcements
        .map((a) => a.id == id ? a.copyWith(read: true) : a)
        .toList();
    state = AsyncData(current.copyWith(announcements: updated));
  }
}

final announcementProvider =
    AsyncNotifierProvider.autoDispose<AnnouncementNotifier, AnnouncementState>(
      AnnouncementNotifier.new,
    );

/// Number of unread announcements (0 while loading or on error).
final unreadAnnouncementCountProvider = Provider.autoDispose<int>((ref) {
  final state = ref.watch(announcementProvider);
  return state.valueOrNull?.announcements.where((a) => !a.read).length ?? 0;
});
