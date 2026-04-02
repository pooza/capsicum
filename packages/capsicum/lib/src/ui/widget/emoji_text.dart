import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';

/// A [Text]-like widget that replaces `:shortcode:` patterns with inline
/// custom-emoji images.
///
/// When no shortcodes are found the widget falls back to a plain [Text].
class EmojiText extends ConsumerWidget {
  final String text;
  final Map<String, String> emojis;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Optional host used to construct a fallback emoji URL
  /// (`https://{host}/emoji/{shortcode}.webp`) when the shortcode is not
  /// found in [emojis].  Set for Misskey posts; leave `null` for Mastodon.
  final String? fallbackHost;

  const EmojiText(
    this.text, {
    super.key,
    this.emojis = const {},
    this.style,
    this.maxLines,
    this.overflow,
    this.fallbackHost,
  });

  static final _shortcodeRegex = RegExp(r':([a-zA-Z0-9_-]+):');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emojiSize = ref.watch(emojiSizeProvider);
    if (emojis.isEmpty && fallbackHost == null) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    if (!_shortcodeRegex.hasMatch(text)) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    final spans = <InlineSpan>[];
    var lastEnd = 0;

    for (final match in _shortcodeRegex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      final shortcode = match.group(1)!;
      final url = _resolveUrl(shortcode);

      if (url != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: emojiSize,
                maxWidth: emojiSize * 3,
              ),
              child: Image.network(
                url,
                height: emojiSize,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    Text(':$shortcode:', style: const TextStyle(fontSize: 14)),
              ),
            ),
          ),
        );
      } else {
        spans.add(TextSpan(text: match.group(0)!));
      }

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return Text.rich(
      TextSpan(children: spans, style: style),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  String? _resolveUrl(String shortcode) {
    final url = emojis[shortcode];
    if (url != null) return url;
    if (fallbackHost != null) {
      return 'https://$fallbackHost/emoji/$shortcode.webp';
    }
    return null;
  }
}
