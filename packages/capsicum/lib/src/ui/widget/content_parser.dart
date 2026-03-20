import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Parsed content node types.
enum _NodeType {
  text,
  bold,
  italic,
  strikethrough,
  code,
  codeBlock,
  center,
  small,
  ruby,
  link,
  mention,
  hashtag,
  url,
  emoji,
  quote,
  fn, // generic $[fn ...] (unhandled — render as plain)
}

class _Node {
  final _NodeType type;
  final String text;
  final List<_Node> children;
  // For ruby: base text + reading
  final String? rubyReading;
  // For link: url
  final String? url;
  // For codeBlock: language
  final String? language;

  const _Node({
    required this.type,
    this.text = '',
    this.children = const [],
    this.rubyReading,
    this.url,
    this.language,
  });

  const _Node.text(this.text)
    : type = _NodeType.text,
      children = const [],
      rubyReading = null,
      url = null,
      language = null;
}

// ---------------------------------------------------------------------------
// MFM Parser
// ---------------------------------------------------------------------------

List<_Node> _parseMfm(String input) {
  return _MfmParser(input).parse();
}

class _MfmParser {
  final String input;
  int _pos = 0;

  _MfmParser(this.input);

  List<_Node> parse() => _parseInline(null);

  List<_Node> _parseInline(String? stopPattern) {
    final nodes = <_Node>[];
    final buf = StringBuffer();

    void flushBuf() {
      if (buf.isNotEmpty) {
        nodes.add(_Node.text(buf.toString()));
        buf.clear();
      }
    }

    while (_pos < input.length) {
      // Check stop pattern
      if (stopPattern != null && _lookingAt(stopPattern)) {
        break;
      }

      final c = input[_pos];

      // Code block: ```
      if (c == '`' && _lookingAt('```')) {
        flushBuf();
        final node = _tryCodeBlock();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Inline code: `
      if (c == '`' && !_lookingAt('```')) {
        flushBuf();
        final node = _tryInlineCode();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Bold: **
      if (c == '*' && _lookingAt('**')) {
        flushBuf();
        final node = _tryDelimited('**', '**', _NodeType.bold);
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Strikethrough: ~~
      if (c == '~' && _lookingAt('~~')) {
        flushBuf();
        final node = _tryDelimited('~~', '~~', _NodeType.strikethrough);
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Italic: single * (not preceded by alnum)
      if (c == '*' &&
          !_lookingAt('**') &&
          (_pos == 0 || !_isAlnum(input[_pos - 1]))) {
        flushBuf();
        final node = _tryDelimited('*', '*', _NodeType.italic, alnumOnly: true);
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // MFM function: $[
      if (c == r'$' && _lookingAt(r'$[')) {
        flushBuf();
        final node = _tryMfmFunction();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // HTML-like tags: <b>, <i>, <s>, <small>, <center>, <plain>
      if (c == '<') {
        flushBuf();
        final node = _tryHtmlTag();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Link: [text](url) or ?[text](url)
      if ((c == '[' ||
          (c == '?' && _pos + 1 < input.length && input[_pos + 1] == '['))) {
        flushBuf();
        final node = _tryLink();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Mention: @user or @user@host
      if (c == '@' && (_pos == 0 || !_isAlnum(input[_pos - 1]))) {
        flushBuf();
        final node = _tryMention();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Hashtag: #tag
      if (c == '#' && (_pos == 0 || !_isAlnum(input[_pos - 1]))) {
        flushBuf();
        final node = _tryHashtag();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // URL
      if (c == 'h' && _lookingAt('http')) {
        flushBuf();
        final node = _tryUrl();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Emoji shortcode
      if (c == ':') {
        flushBuf();
        final node = _tryEmoji();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      // Quote block: > at start of line
      if (c == '>' && (_pos == 0 || input[_pos - 1] == '\n')) {
        flushBuf();
        final node = _tryQuote();
        if (node != null) {
          nodes.add(node);
          continue;
        }
      }

      buf.write(c);
      _pos++;
    }

    flushBuf();
    return nodes;
  }

  // --- Helpers ---

  bool _lookingAt(String s) {
    if (_pos + s.length > input.length) return false;
    return input.substring(_pos, _pos + s.length) == s;
  }

  bool _isAlnum(String c) => RegExp(r'[a-zA-Z0-9]').hasMatch(c);

  // --- Parsers ---

  bool get _atLineStart => _pos == 0 || input[_pos - 1] == '\n';

  _Node? _tryCodeBlock() {
    if (!_atLineStart || !_lookingAt('```')) return null;
    final start = _pos;
    _pos += 3;
    // Optional language
    final langBuf = StringBuffer();
    while (_pos < input.length && input[_pos] != '\n') {
      langBuf.write(input[_pos]);
      _pos++;
    }
    if (_pos < input.length) _pos++; // skip \n
    final codeBuf = StringBuffer();
    while (_pos < input.length) {
      if (_atLineStart && _lookingAt('```')) {
        _pos += 3;
        final lang = langBuf.toString().trim();
        return _Node(
          type: _NodeType.codeBlock,
          text: codeBuf.toString().trimRight(),
          language: lang.isEmpty ? null : lang,
        );
      }
      codeBuf.write(input[_pos]);
      _pos++;
    }
    // No closing ``` found
    _pos = start;
    return null;
  }

  _Node? _tryInlineCode() {
    if (input[_pos] != '`') return null;
    final start = _pos;
    _pos++;
    final buf = StringBuffer();
    while (_pos < input.length) {
      if (input[_pos] == '`') {
        _pos++;
        if (buf.isEmpty) {
          _pos = start;
          return null;
        }
        return _Node(type: _NodeType.code, text: buf.toString());
      }
      if (input[_pos] == '\n') {
        _pos = start;
        return null;
      }
      buf.write(input[_pos]);
      _pos++;
    }
    _pos = start;
    return null;
  }

  _Node? _tryDelimited(
    String open,
    String close,
    _NodeType type, {
    bool alnumOnly = false,
  }) {
    if (!_lookingAt(open)) return null;
    final start = _pos;
    _pos += open.length;
    if (alnumOnly) {
      // Content restricted to alnum + space + tab
      final buf = StringBuffer();
      while (_pos < input.length && !_lookingAt(close)) {
        final c = input[_pos];
        if (c == '\n') break;
        buf.write(c);
        _pos++;
      }
      if (_lookingAt(close) && buf.isNotEmpty) {
        _pos += close.length;
        return _Node(type: type, children: [_Node.text(buf.toString())]);
      }
      _pos = start;
      return null;
    }
    final children = _parseInline(close);
    if (_lookingAt(close) && children.isNotEmpty) {
      _pos += close.length;
      return _Node(type: type, children: children);
    }
    _pos = start;
    return null;
  }

  _Node? _tryMfmFunction() {
    if (!_lookingAt(r'$[')) return null;
    final start = _pos;
    _pos += 2;
    // Parse function name
    final nameBuf = StringBuffer();
    while (_pos < input.length &&
        RegExp(r'[a-zA-Z0-9_]').hasMatch(input[_pos])) {
      nameBuf.write(input[_pos]);
      _pos++;
    }
    if (nameBuf.isEmpty) {
      _pos = start;
      return null;
    }
    final fnName = nameBuf.toString().toLowerCase();
    // Skip args (dot-separated)
    if (_pos < input.length && input[_pos] == '.') {
      while (_pos < input.length && input[_pos] != ' ' && input[_pos] != ']') {
        _pos++;
      }
    }
    // Expect space
    if (_pos >= input.length || input[_pos] != ' ') {
      _pos = start;
      return null;
    }
    _pos++; // skip space

    if (fnName == 'ruby') {
      return _parseRubyContent(start);
    }

    // Generic function: parse content until ]
    final children = _parseInline(']');
    if (_pos < input.length && input[_pos] == ']') {
      _pos++;
      // For unhandled functions, render children as-is
      return _Node(type: _NodeType.fn, children: children);
    }
    _pos = start;
    return null;
  }

  _Node? _parseRubyContent(int start) {
    // $[ruby base reading] — content until ]
    // Find the closing ]
    final contentStart = _pos;
    var depth = 1;
    var closePos = -1;
    for (var i = _pos; i < input.length; i++) {
      if (input[i] == '[') depth++;
      if (input[i] == ']') {
        depth--;
        if (depth == 0) {
          closePos = i;
          break;
        }
      }
    }
    if (closePos == -1) {
      _pos = start;
      return null;
    }
    final content = input.substring(contentStart, closePos);
    _pos = closePos + 1;
    // Split on last space
    final lastSpace = content.lastIndexOf(' ');
    if (lastSpace <= 0) {
      // No reading found, treat as plain text
      return _Node.text(content);
    }
    final base = content.substring(0, lastSpace);
    final reading = content.substring(lastSpace + 1);
    return _Node(type: _NodeType.ruby, text: base, rubyReading: reading);
  }

  _Node? _tryHtmlTag() {
    if (input[_pos] != '<') return null;
    final start = _pos;

    // Try each supported tag
    for (final tag in ['b', 'i', 's', 'small', 'center', 'plain']) {
      if (_lookingAt('<$tag>')) {
        _pos += tag.length + 2;
        final closeTag = '</$tag>';
        if (tag == 'plain') {
          // Plain: raw text, no parsing
          final endIdx = input.indexOf(closeTag, _pos);
          if (endIdx == -1) {
            _pos = start;
            continue;
          }
          final text = input.substring(_pos, endIdx);
          _pos = endIdx + closeTag.length;
          return _Node.text(text);
        }
        final type = switch (tag) {
          'b' => _NodeType.bold,
          'i' => _NodeType.italic,
          's' => _NodeType.strikethrough,
          'small' => _NodeType.small,
          'center' => _NodeType.center,
          _ => _NodeType.text,
        };
        final children = _parseInline(closeTag);
        if (_lookingAt(closeTag)) {
          _pos += closeTag.length;
          return _Node(type: type, children: children);
        }
        _pos = start;
        return null;
      }
    }
    return null;
  }

  _Node? _tryLink() {
    final start = _pos;
    // Skip optional ?
    if (input[_pos] == '?') _pos++;
    if (_pos >= input.length || input[_pos] != '[') {
      _pos = start;
      return null;
    }
    _pos++; // skip [
    // Find ]
    final textBuf = StringBuffer();
    var depth = 1;
    while (_pos < input.length) {
      if (input[_pos] == '[') depth++;
      if (input[_pos] == ']') {
        depth--;
        if (depth == 0) break;
      }
      textBuf.write(input[_pos]);
      _pos++;
    }
    if (_pos >= input.length || input[_pos] != ']') {
      _pos = start;
      return null;
    }
    _pos++; // skip ]
    // Expect (url)
    if (_pos >= input.length || input[_pos] != '(') {
      _pos = start;
      return null;
    }
    _pos++; // skip (
    final urlBuf = StringBuffer();
    while (_pos < input.length && input[_pos] != ')') {
      urlBuf.write(input[_pos]);
      _pos++;
    }
    if (_pos >= input.length) {
      _pos = start;
      return null;
    }
    _pos++; // skip )
    return _Node(
      type: _NodeType.link,
      text: textBuf.toString(),
      url: urlBuf.toString(),
    );
  }

  _Node? _tryMention() {
    if (input[_pos] != '@') return null;
    final start = _pos;
    _pos++; // skip @
    final userBuf = StringBuffer();
    while (_pos < input.length &&
        RegExp(r'[a-zA-Z0-9_.-]').hasMatch(input[_pos])) {
      userBuf.write(input[_pos]);
      _pos++;
    }
    if (userBuf.isEmpty) {
      _pos = start;
      return null;
    }
    var mention = '@${userBuf.toString()}';
    // Optional @host
    if (_pos < input.length && input[_pos] == '@') {
      _pos++;
      final hostBuf = StringBuffer();
      while (_pos < input.length &&
          RegExp(r'[a-zA-Z0-9_.-]').hasMatch(input[_pos])) {
        hostBuf.write(input[_pos]);
        _pos++;
      }
      if (hostBuf.isNotEmpty) {
        mention += '@${hostBuf.toString()}';
      }
    }
    return _Node(type: _NodeType.mention, text: mention);
  }

  _Node? _tryHashtag() {
    if (input[_pos] != '#') return null;
    final start = _pos;
    _pos++; // skip #
    final tagBuf = StringBuffer();
    // Hashtags allow word characters (including CJK) but not whitespace or
    // common punctuation that terminates a tag.
    while (_pos < input.length) {
      final c = input.codeUnitAt(_pos);
      // Stop on ASCII whitespace, control characters, or tag-terminating
      // punctuation: . , ! ? ; : ( ) [ ] { } < > " ' ` # @
      if (c <= 0x20 ||
          c == 0x2e || // .
          c == 0x2c || // ,
          c == 0x21 || // !
          c == 0x3f || // ?
          c == 0x3b || // ;
          c == 0x3a || // :
          c == 0x28 || // (
          c == 0x29 || // )
          c == 0x5b || // [
          c == 0x5d || // ]
          c == 0x7b || // {
          c == 0x7d || // }
          c == 0x3c || // <
          c == 0x3e || // >
          c == 0x22 || // "
          c == 0x27 || // '
          c == 0x60 || // `
          c == 0x23 || // #
          c == 0x40) {
        // @
        break;
      }
      tagBuf.write(input[_pos]);
      _pos++;
    }
    if (tagBuf.isEmpty) {
      _pos = start;
      return null;
    }
    return _Node(type: _NodeType.hashtag, text: tagBuf.toString());
  }

  _Node? _tryUrl() {
    final urlPattern = RegExp(r'https?://[^\s<>\]）」』】]+');
    final match = urlPattern.matchAsPrefix(input, _pos);
    if (match == null) return null;
    _pos = match.end;
    return _Node(type: _NodeType.url, text: match.group(0)!);
  }

  _Node? _tryEmoji() {
    final match = RegExp(r':([a-zA-Z0-9_-]+):').matchAsPrefix(input, _pos);
    if (match == null) return null;
    _pos = match.end;
    return _Node(type: _NodeType.emoji, text: match.group(1)!);
  }

  _Node? _tryQuote() {
    if (_pos > 0 && input[_pos - 1] != '\n') return null;
    if (input[_pos] != '>') return null;

    final lines = <String>[];
    while (_pos < input.length && input[_pos] == '>') {
      _pos++; // skip >
      if (_pos < input.length && input[_pos] == ' ') {
        _pos++; // skip optional space
      }
      final lineBuf = StringBuffer();
      while (_pos < input.length && input[_pos] != '\n') {
        lineBuf.write(input[_pos]);
        _pos++;
      }
      lines.add(lineBuf.toString());
      if (_pos < input.length) _pos++; // skip \n
    }
    final quoteText = lines.join('\n');
    final children = _MfmParser(quoteText).parse();
    return _Node(type: _NodeType.quote, children: children);
  }
}

// ---------------------------------------------------------------------------
// HTML Parser (Mastodon)
// ---------------------------------------------------------------------------

List<_Node> _parseHtml(String html) {
  // Decode to intermediate text, preserving structure
  var text = html
      .replaceAll(RegExp(r'<br\s*/?>'), '\n')
      .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
      // Preserve <code> as backticks before stripping all tags
      .replaceAllMapped(
        RegExp(r'<code>([^<]*)</code>', caseSensitive: false),
        (m) => '`${m[1]}`',
      )
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m[1]!)),
      )
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
      );
  // Re-parse for URLs, emoji, hashtags, mentions using MFM parser
  // (these patterns are shared)
  return _parseMfm(text);
}

// ---------------------------------------------------------------------------
// Renderer: Node tree → InlineSpan
// ---------------------------------------------------------------------------

typedef EmojiResolver = String? Function(String shortcode);
typedef LinkTapCallback = void Function(String url);
typedef HashtagTapCallback = void Function(String tag);
typedef MentionTapCallback = void Function(String mention);

class ContentRenderer {
  final TextStyle baseStyle;
  final EmojiResolver resolveEmoji;
  final LinkTapCallback? onLinkTap;
  final HashtagTapCallback? onHashtagTap;
  final MentionTapCallback? onMentionTap;
  final List<GestureRecognizer> _recognizers = [];

  ContentRenderer({
    required this.baseStyle,
    required this.resolveEmoji,
    this.onLinkTap,
    this.onHashtagTap,
    this.onMentionTap,
  });

  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  /// Render MFM text to a TextSpan.
  TextSpan renderMfm(String input) {
    final nodes = _parseMfm(input);
    return TextSpan(children: _renderNodes(nodes, baseStyle), style: baseStyle);
  }

  /// Render Mastodon HTML to a TextSpan.
  TextSpan renderHtml(String html) {
    final nodes = _parseHtml(html);
    return TextSpan(children: _renderNodes(nodes, baseStyle), style: baseStyle);
  }

  List<InlineSpan> _renderNodes(List<_Node> nodes, TextStyle style) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      spans.addAll(_renderNode(node, style));
    }
    return spans;
  }

  List<InlineSpan> _renderNode(_Node node, TextStyle style) {
    switch (node.type) {
      case _NodeType.text:
        return _buildTextWithEmoji(node.text, style);

      case _NodeType.bold:
        final boldStyle = style.copyWith(fontWeight: FontWeight.bold);
        return _renderNodes(node.children, boldStyle);

      case _NodeType.italic:
        final italicStyle = style.copyWith(fontStyle: FontStyle.italic);
        return _renderNodes(node.children, italicStyle);

      case _NodeType.strikethrough:
        final strikeStyle = style.copyWith(
          decoration: TextDecoration.lineThrough,
        );
        return _renderNodes(node.children, strikeStyle);

      case _NodeType.code:
        return [
          TextSpan(
            text: node.text,
            style: style.copyWith(
              fontFamily: 'monospace',
              fontSize: (style.fontSize ?? 14) * 0.9,
              backgroundColor: Colors.grey.withValues(alpha: 0.2),
            ),
          ),
        ];

      case _NodeType.codeBlock:
        return [
          TextSpan(text: '\n', style: style),
          WidgetSpan(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                node.text,
                style: style.copyWith(
                  fontFamily: 'monospace',
                  fontSize: (style.fontSize ?? 14) * 0.9,
                ),
              ),
            ),
          ),
          TextSpan(text: '\n', style: style),
        ];

      case _NodeType.center:
        return [
          WidgetSpan(
            child: Text.rich(
              TextSpan(children: _renderNodes(node.children, style)),
              textAlign: TextAlign.center,
            ),
          ),
        ];

      case _NodeType.small:
        final smallStyle = style.copyWith(
          fontSize: (style.fontSize ?? 14) * 0.8,
          color: style.color?.withValues(alpha: 0.7),
        );
        return _renderNodes(node.children, smallStyle);

      case _NodeType.ruby:
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _RubyWidget(
              base: node.text,
              reading: node.rubyReading ?? '',
              baseStyle: style,
            ),
          ),
        ];

      case _NodeType.link:
        final recognizer = TapGestureRecognizer()
          ..onTap = () => onLinkTap?.call(node.url ?? '');
        _recognizers.add(recognizer);
        return [
          TextSpan(
            text: node.text,
            style: style.copyWith(color: Colors.blue),
            recognizer: recognizer,
          ),
        ];

      case _NodeType.mention:
        final recognizer = TapGestureRecognizer()
          ..onTap = () => onMentionTap?.call(node.text);
        _recognizers.add(recognizer);
        return [
          TextSpan(
            text: node.text,
            style: style.copyWith(color: Colors.blue),
            recognizer: recognizer,
          ),
        ];

      case _NodeType.hashtag:
        final recognizer = TapGestureRecognizer()
          ..onTap = () => onHashtagTap?.call(node.text);
        _recognizers.add(recognizer);
        return [
          TextSpan(
            text: '#${node.text}',
            style: style.copyWith(color: Colors.blue),
            recognizer: recognizer,
          ),
        ];

      case _NodeType.url:
        final url = node.text;
        final uri = Uri.tryParse(url) ?? Uri.tryParse(Uri.encodeFull(url));
        final isSafe =
            uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
        final recognizer = TapGestureRecognizer()
          ..onTap = isSafe ? () => launchUrl(uri) : null;
        _recognizers.add(recognizer);
        final displayUrl = uri != null ? Uri.decodeFull(uri.toString()) : url;
        return [
          TextSpan(
            text: displayUrl,
            style: style.copyWith(color: Colors.blue),
            recognizer: recognizer,
          ),
        ];

      case _NodeType.emoji:
        final emojiUrl = resolveEmoji(node.text);
        if (emojiUrl != null) {
          return [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 20, maxWidth: 60),
                child: Image.network(
                  emojiUrl,
                  height: 20,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Text(
                    ':${node.text}:',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
          ];
        }
        return [TextSpan(text: ':${node.text}:', style: style)];

      case _NodeType.quote:
        return [
          TextSpan(text: '\n', style: style),
          WidgetSpan(
            child: Container(
              padding: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: style.color?.withValues(alpha: 0.4) ?? Colors.grey,
                    width: 3,
                  ),
                ),
              ),
              child: Text.rich(
                TextSpan(
                  children: _renderNodes(
                    node.children,
                    style.copyWith(color: style.color?.withValues(alpha: 0.7)),
                  ),
                ),
              ),
            ),
          ),
          TextSpan(text: '\n', style: style),
        ];

      case _NodeType.fn:
        // Unhandled $[fn ...] — render children as-is
        return _renderNodes(node.children, style);
    }
  }

  // Emoji ranges for Unicode emoji detection.
  static final _emojiRegex = RegExp(
    r'(?:[\u{1F1E0}-\u{1F1FF}]{2}'
    r'|[\u{1F000}-\u{1FFFF}]'
    r'|[\u{2600}-\u{27BF}]'
    r'|[\u{2300}-\u{23FF}]'
    r'|[\u{2B50}\u{2B55}]'
    r'|[\u{2934}\u{2935}]'
    r'|[\u{25AA}-\u{25FE}]'
    r'|[\u{2B05}-\u{2B1C}]'
    r'|[\u{3030}\u{303D}\u{3297}\u{3299}]'
    r'|[\u{00A9}\u{00AE}]'
    r')'
    r'[\u{FE0E}\u{FE0F}\u{200D}\u{20E3}\u{1F3FB}-\u{1F3FF}'
    r'\u{E0020}-\u{E007F}'
    r'\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\u{2300}-\u{23FF}]*',
    unicode: true,
  );

  List<InlineSpan> _buildTextWithEmoji(String text, TextStyle style) {
    final matches = _emojiRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: text, style: style)];
    }
    final spans = <InlineSpan>[];
    var lastEnd = 0;
    final emojiSize = style.fontSize ?? 14.0;
    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(text: text.substring(lastEnd, match.start), style: style),
        );
      }
      final emoji = match.group(0)!;
      final codepoints = emoji.runes
          .where((r) => r != 0xFE0F && r != 0xFE0E)
          .map((r) => r.toRadixString(16))
          .join('-');
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Image.network(
            'https://cdn.jsdelivr.net/gh/twitter/twemoji@latest/assets/72x72/$codepoints.png',
            width: emojiSize,
            height: emojiSize,
            errorBuilder: (_, _, _) => Text(emoji, style: style),
          ),
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: style));
    }
    return spans;
  }
}

// ---------------------------------------------------------------------------
// Ruby Widget
// ---------------------------------------------------------------------------

class _RubyWidget extends StatelessWidget {
  final String base;
  final String reading;
  final TextStyle baseStyle;

  const _RubyWidget({
    required this.base,
    required this.reading,
    required this.baseStyle,
  });

  @override
  Widget build(BuildContext context) {
    final readingSize = (baseStyle.fontSize ?? 14) * 0.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          reading,
          style: baseStyle.copyWith(fontSize: readingSize, height: 1),
        ),
        Text(base, style: baseStyle.copyWith(height: 1)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Hashtag extraction (preserved from original)
// ---------------------------------------------------------------------------

/// Extract trailing hashtags from MFM content.
({String body, List<String> trailingTags}) extractTrailingTagsMfm(String text) {
  final trailingTagLine = RegExp(r'\n\n((?:#\S+\s*)+)$');
  final match = trailingTagLine.firstMatch(text);
  if (match != null) {
    final tagLine = match.group(1)!;
    final tagPattern = RegExp(r'#(\S+)');
    final tags = [for (final m in tagPattern.allMatches(tagLine)) m.group(1)!];
    return (
      body: text.substring(0, match.start).trimRight(),
      trailingTags: tags,
    );
  }
  return (body: text, trailingTags: const []);
}

/// Extract trailing hashtags from Mastodon HTML content.
({String body, List<String> trailingTags}) extractTrailingTagsHtml(
  String html,
) {
  final trailingTags = <String>[];
  var bodyHtml = html;

  // Mastodon native: <a class="...hashtag..." href="...">#<span>tag</span></a>
  // Misskey federated: <a href="...">#tag</a> (no class="hashtag")
  final trailingTagBlock = RegExp(
    r'<p>\s*((<a[^>]*>.*?</a>\s*)+)</p>\s*$',
    caseSensitive: false,
  );
  final blockMatch = trailingTagBlock.firstMatch(bodyHtml);
  if (blockMatch != null) {
    final tagBlockHtml = blockMatch.group(1)!;
    // Check that ALL <a> tags in the block are hashtag links.
    final allAnchors = RegExp(r'<a[^>]*>(.*?)</a>');
    final anchors = allAnchors.allMatches(tagBlockHtml).toList();
    final hashtagAnchor = RegExp(
      r'<a[^>]*>#(?:<span>)?([^<]+)(?:</span>)?</a>',
    );
    final hashMatches = hashtagAnchor.allMatches(tagBlockHtml).toList();
    // Verify that every anchor is a hashtag anchor.
    final withoutAnchors = tagBlockHtml.replaceAll(allAnchors, '').trim();
    if (withoutAnchors.isEmpty &&
        anchors.length == hashMatches.length &&
        hashMatches.isNotEmpty) {
      for (final m in hashMatches) {
        trailingTags.add(m.group(1)!);
      }
      bodyHtml = bodyHtml.substring(0, blockMatch.start).trimRight();
    }
  }

  return (body: bodyHtml, trailingTags: trailingTags);
}
