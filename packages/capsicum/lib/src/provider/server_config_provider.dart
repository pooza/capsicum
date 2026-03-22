import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/server_metadata_cache.dart';
import 'account_manager_provider.dart';

/// Host → theme color map from mulukhiya services (logged-in servers only).
final hostThemeColorProvider = Provider<Map<String, Color>>((ref) {
  final accounts = ref.watch(accountManagerProvider).accounts;
  final map = <String, Color>{};
  for (final account in accounts) {
    final hex = account.mulukhiya?.themeColorHex;
    if (hex != null && hex.startsWith('#') && hex.length >= 7) {
      try {
        map[account.key.host] = Color(
          0xFF000000 | int.parse(hex.substring(1, 7), radix: 16),
        );
      } catch (_) {}
    }
  }
  return map;
});

/// Resolve theme color for a host.
/// Priority: mulukhiya → server API cache → deterministic fallback.
Color resolveHostColor(Map<String, Color> mulukhiyaColors, String host) {
  final mulukhiya = mulukhiyaColors[host];
  if (mulukhiya != null) return mulukhiya;

  final cached = ServerMetadataCache.instance.getCached(host);
  final hex = cached?.themeColor;
  if (hex != null) {
    final parsed = _parseHexColor(hex);
    if (parsed != null) return parsed;
  }

  // Deterministic fallback based on host hash.
  return HSLColor.fromAHSL(1, host.hashCode % 360, 0.4, 0.45).toColor();
}

Color? _parseHexColor(String hex) {
  final raw = hex.startsWith('#') ? hex.substring(1) : hex;
  if (raw.length < 6) return null;
  try {
    return Color(0xFF000000 | int.parse(raw.substring(0, 6), radix: 16));
  } catch (_) {
    return null;
  }
}

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

/// URL of the :sabacan: custom emoji on the current server (null if unavailable).
final sabacanUrlProvider = FutureProvider<String?>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter is! CustomEmojiSupport) return null;
  try {
    final emojis = await (adapter as CustomEmojiSupport).getEmojis();
    final sabacan = emojis.where((e) => e.shortcode == 'sabacan').firstOrNull;
    return sabacan?.url;
  } catch (_) {
    return null;
  }
});

/// Local timeline display name: use default hashtag if available.
final localTimelineNameProvider = Provider<String>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  final tag = mulukhiya?.defaultHashtag;
  return tag != null ? '#$tag' : 'ローカル';
});
