import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';

/// The label to use for "post" actions (e.g. "キュア！" on precure.fun).
final postLabelProvider = Provider<String>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  return mulukhiya?.postLabel ?? '投稿';
});

/// The label to use for "boost/renote" actions (e.g. "リキュア" on precure.fun).
final reblogLabelProvider = Provider<String>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  if (mulukhiya?.reblogLabel != null) return mulukhiya!.reblogLabel!;
  final adapter = ref.watch(currentAdapterProvider);
  return adapter is ReactionSupport ? 'リノート' : 'ブースト';
});

/// Maximum post content length from mulukhiya, falling back to adapter default.
final maxPostLengthProvider = Provider<int?>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  final adapter = ref.watch(currentAdapterProvider);
  return mulukhiya?.maxPostLength ?? adapter?.capabilities.maxPostContentLength;
});

/// Theme seed color from the server's theme configuration.
final themeSeedColorProvider = Provider<Color>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  final hex = mulukhiya?.themeColorHex;
  if (hex != null && hex.startsWith('#') && hex.length >= 7) {
    try {
      final colorValue = int.parse(hex.substring(1, 7), radix: 16);
      return Color(0xFF000000 | colorValue);
    } catch (_) {}
  }
  return Colors.green;
});

/// Local timeline display name: use default hashtag if available.
final localTimelineNameProvider = Provider<String>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  final tag = mulukhiya?.defaultHashtag;
  return tag != null ? '#$tag' : 'ローカル';
});
