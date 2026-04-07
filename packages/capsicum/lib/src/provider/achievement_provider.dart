import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';

/// Fetches achievements for the given [userId].
final achievementProvider = FutureProvider.autoDispose
    .family<List<Achievement>, String>((ref, userId) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter == null || adapter is! AchievementSupport) return [];
      return (adapter as AchievementSupport).getAchievements(userId);
    });
