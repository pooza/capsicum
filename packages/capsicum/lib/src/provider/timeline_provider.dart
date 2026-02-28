import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';

/// Provider for the home timeline posts.
final homeTimelineProvider = FutureProvider<List<Post>>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null) return [];
  return adapter.getTimeline(TimelineType.home);
});
