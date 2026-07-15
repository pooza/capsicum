import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:capsicum_core/capsicum_core.dart' show nyaize;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../url_helper.dart';
import 'mfm_animation.dart';
import 'package:html_unescape/html_unescape.dart';

final _unescape = HtmlUnescape();

/// HTML タグを除去し、文字参照をデコードしてプレーンテキストにする。
String stripHtml(String html) {
  return _unescape.convert(
    html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), ''),
  );
}

/// 「削除して再編集」(redraft) 専用の平文化 (#703)。
///
/// Mastodon の mention anchor は可視テキストが `@user`（ローカル部のみ）で、
/// host は `<a href>` 側にしか無い。そのまま [stripHtml] すると host が落ち、
/// リモートアカウント宛が `@user` だけになって再投稿時にローカルの別人へ飛ぶ
/// / 解決されない。ここでは平文化の前に mention anchor だけ href の host を
/// 使って `@user@host` に展開してから [stripHtml] に渡す。
///
/// [localHost] は現在ログイン中アカウントのサーバー host。ローカル宛メンション
/// （host == [localHost]）は従来どおり `@user` のままにする。Misskey の MFM は
/// 元から `@user@host` が本文にあるため、この経路は通さない（呼び出し側で
/// `isHtml` の Mastodon コンテンツにのみ適用する）。
String stripHtmlRestoringMentions(String html, {required String localHost}) {
  final expanded = html.replaceAllMapped(
    RegExp(
      r'<a\b[^>]*?\bhref="([^"]*)"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    ),
    (m) {
      final url = m[1]!;
      // 内側の <span> 等を除いた可視ラベル。
      final label = m[2]!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      // mention anchor 以外（リンク / ハッシュタグ）は触らず、そのまま
      // [stripHtml] の一括タグ除去に委ねる。
      if (!label.startsWith('@')) return m[0]!;
      // 既に `@user@host` 形式なら触らない。
      if (label.indexOf('@', 1) != -1) return m[0]!;
      final host = Uri.tryParse(url)?.host;
      if (host == null || host.isEmpty || host == localHost) return label;
      return '$label@$host';
    },
  );
  return stripHtml(expanded);
}

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
  // For fn: function name and args string (e.g. "fg", "color=ff0000")
  final String? fnName;
  final String? fnArgs;

  const _Node({
    required this.type,
    this.text = '',
    this.children = const [],
    this.rubyReading,
    this.url,
    this.language,
    this.fnName,
    this.fnArgs,
  });

  const _Node.text(this.text)
    : type = _NodeType.text,
      children = const [],
      rubyReading = null,
      url = null,
      language = null,
      fnName = null,
      fnArgs = null;
}

// ---------------------------------------------------------------------------
// MFM Parser
// ---------------------------------------------------------------------------

List<_Node> _parseMfm(String input) {
  return _MfmParser(input).parse();
}

/// 入力文字列から MFM parser がハッシュタグとして抽出した文字列の一覧を返す。
/// content_parser の private な node tree を外部に晒さず、Issue #566 の挙動を
/// 単体テストできるようにするための薄い helper。
@visibleForTesting
List<String> parseHashtagsForTesting(String input) {
  final result = <String>[];
  void walk(List<_Node> nodes) {
    for (final n in nodes) {
      if (n.type == _NodeType.hashtag) result.add(n.text);
      if (n.children.isNotEmpty) walk(n.children);
    }
  }

  walk(_parseMfm(input));
  return result;
}

/// 投稿本文からハッシュタグ名（先頭 `#` を除いたタグ文字列）を出現順・重複除去で
/// 抽出する。Mastodon(HTML) / Misskey(MFM) 両対応（`isHtml` でパーサを選ぶ）。
/// 本文コピー導線（#794「全ハッシュタグをコピー」）で使う。
List<String> extractHashtags(String content, {required bool isHtml}) {
  final result = <String>[];
  final seen = <String>{};
  void walk(List<_Node> nodes) {
    for (final n in nodes) {
      if (n.type == _NodeType.hashtag && seen.add(n.text)) {
        result.add(n.text);
      }
      if (n.children.isNotEmpty) walk(n.children);
    }
  }

  walk(isHtml ? _parseHtml(content) : _parseMfm(content));
  return result;
}

/// `_parseHtml`（Mastodon HTML 経路）の結果を単体テストするための helper。
/// link / url / hashtag ノードと、未変換の生 `<a` タグがテキストとして
/// 露出していないか（Issue #595）を検証できるようにする。
@visibleForTesting
({
  List<({String text, String url})> links,
  List<String> urls,
  List<String> hashtags,
  bool hasRawTag,
})
parseHtmlForTesting(String html) {
  final links = <({String text, String url})>[];
  final urls = <String>[];
  final hashtags = <String>[];
  var hasRawTag = false;
  void walk(List<_Node> nodes) {
    for (final n in nodes) {
      switch (n.type) {
        case _NodeType.link:
          links.add((text: n.text, url: n.url ?? ''));
        case _NodeType.url:
          urls.add(n.text);
        case _NodeType.hashtag:
          hashtags.add(n.text);
        case _NodeType.text:
          if (n.text.contains('<a')) hasRawTag = true;
        default:
          break;
      }
      if (n.children.isNotEmpty) walk(n.children);
    }
  }

  walk(_parseHtml(html));
  return (links: links, urls: urls, hashtags: hashtags, hasRawTag: hasRawTag);
}

class _MfmParser {
  final String input;
  int _pos = 0;

  _MfmParser(this.input);

  // Mastodon HASHTAG_NAME_RE 相当のハッシュタグ仕様 (#566)。
  //  - 直前境界: Mastodon の lookbehind `(?<![=\/)\w])` に揃え、ASCII word
  //    (`\w` = [A-Za-z0-9_]) と =, /, ) の直後を不可とする。日本語等の
  //    Unicode 文字直後はタグ成立を許す (Mastodon と同じ)
  //  - 許可文字: Unicode L / M / N + _ · -
  //  - 内容要件: タグ部分に Unicode letter を 1 文字以上含む (数字のみ拒否)
  // Misskey MFM の括弧ネスト挙動 (「」() 内をタグに含む) は未対応 — 実害報告
  // が出た段階で別途扱う。
  static final _hashtagBoundaryBefore = RegExp(r'[=/)\w]');
  static final _hashtagChar = RegExp(r'[\p{L}\p{N}\p{M}_·\-]', unicode: true);
  static final _hashtagHasLetter = RegExp(r'\p{L}', unicode: true);

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
    // Parse args (dot-separated, e.g. ".color=ff0000")
    String? fnArgs;
    if (_pos < input.length && input[_pos] == '.') {
      final argsStart = _pos + 1; // skip leading dot
      while (_pos < input.length && input[_pos] != ' ' && input[_pos] != ']') {
        _pos++;
      }
      fnArgs = input.substring(argsStart, _pos);
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
      return _Node(
        type: _NodeType.fn,
        children: children,
        fnName: fnName,
        fnArgs: fnArgs,
      );
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
    // 直前境界チェック: =, /, ), word char (L/M/N + _) の直後の # はタグにしない
    if (_pos > 0 && _hashtagBoundaryBefore.hasMatch(input[_pos - 1])) {
      return null;
    }
    final start = _pos;
    _pos++; // skip #
    final tagBuf = StringBuffer();
    while (_pos < input.length) {
      final c = input[_pos];
      if (!_hashtagChar.hasMatch(c)) break;
      tagBuf.write(c);
      _pos++;
    }
    final tag = tagBuf.toString();
    // 数字 / 記号のみは拒否 (Mastodon は [[:alpha:]_·] を 1 文字以上要求)
    if (tag.isEmpty || !_hashtagHasLetter.hasMatch(tag)) {
      _pos = start;
      return null;
    }
    return _Node(type: _NodeType.hashtag, text: tag);
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
  // Decode to intermediate text, preserving structure.
  // Order matters: convert MFM-origin HTML elements to MFM syntax BEFORE
  // stripping remaining tags, so the MFM parser can render them.
  var text = html
      .replaceAll(RegExp(r'<br\s*/?>'), '\n')
      .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
      // Preserve <pre><code> as code block before handling inline <code>
      .replaceAllMapped(
        RegExp(
          r'<pre>(?:<code[^>]*>)?(.*?)(?:</code>)?</pre>',
          caseSensitive: false,
          dotAll: true,
        ),
        (m) => '\n```\n${m[1]}\n```\n',
      )
      // Preserve inline <code> as backticks before stripping all tags
      .replaceAllMapped(
        RegExp(r'<code>([^<]*)</code>', caseSensitive: false),
        (m) => '`${m[1]}`',
      )
      // --- MFM-origin HTML → MFM syntax (before tag stripping) ---
      // <ruby>base<rp>…</rp><rt>reading</rt><rp>…</rp></ruby>
      .replaceAllMapped(
        RegExp(
          r'<ruby>(.*?)(?:<rp>[^<]*</rp>)?<rt>(.*?)</rt>(?:<rp>[^<]*</rp>)?</ruby>',
          caseSensitive: false,
        ),
        (m) =>
            r'$[ruby '
            '${m[1]} ${m[2]}]',
      )
      // <del>text</del> → <s>text</s> (MFM parser handles <s>)
      .replaceAllMapped(
        RegExp(r'<del>(.*?)</del>', caseSensitive: false, dotAll: true),
        (m) => '<s>${m[1]}</s>',
      )
      // <strong>text</strong> → <b>text</b>
      .replaceAllMapped(
        RegExp(r'<strong>(.*?)</strong>', caseSensitive: false, dotAll: true),
        (m) => '<b>${m[1]}</b>',
      )
      // <em>text</em> → <i>text</i>
      .replaceAllMapped(
        RegExp(r'<em>(.*?)</em>', caseSensitive: false, dotAll: true),
        (m) => '<i>${m[1]}</i>',
      )
      // <blockquote>text</blockquote> → > quoted lines
      .replaceAllMapped(
        RegExp(
          r'<blockquote>(.*?)</blockquote>',
          caseSensitive: false,
          dotAll: true,
        ),
        (m) {
          final inner = m[1]!
              .replaceAll(RegExp(r'<br\s*/?>'), '\n')
              .replaceAll(RegExp(r'<[^>]*>'), '');
          final quoted = inner.split('\n').map((line) => '> $line').join('\n');
          return '\n$quoted\n';
        },
      )
      // <span style="color: #hex"> → $[fg.color=hex ...]
      .replaceAllMapped(
        RegExp(
          r'<span\s+style="color:\s*#?([0-9a-fA-F]{3,8})\s*;?\s*">(.*?)</span>',
          caseSensitive: false,
          dotAll: true,
        ),
        (m) =>
            r'$[fg.color='
            '${m[1]} ${m[2]}]',
      )
      // <span style="font-size: N%"> → $[x2/x3/x4 ...]
      .replaceAllMapped(
        RegExp(
          r'<span\s+style="font-size:\s*(\d+)%\s*;?\s*">(.*?)</span>',
          caseSensitive: false,
          dotAll: true,
        ),
        (m) {
          final pct = int.tryParse(m[1]!) ?? 100;
          final fn = pct >= 400
              ? 'x4'
              : pct >= 300
              ? 'x3'
              : pct >= 200
              ? 'x2'
              : null;
          return fn != null ? '\$[$fn ${m[2]}]' : m[2]!;
        },
      )
      // <div style="text-align: center"> → <center> (Misskey AP output)
      .replaceAllMapped(
        RegExp(
          r'<div\s+style="text-align:\s*center\s*;?\s*">(.*?)</div>',
          caseSensitive: false,
          dotAll: true,
        ),
        (m) => '<center>${m[1]}</center>',
      )
      // <a href="url">text</a> → MFM のリンク / ハッシュタグ / メンション。
      // Misskey 由来の連合ノートは <a> を含む HTML を素で投げてくるため、
      // 一括タグ除去で href を失う前に MFM 構文へ変換しておく。Mastodon は
      // rel / target / class を付与するので属性は緩く読み飛ばす。
      .replaceAllMapped(
        RegExp(
          r'<a\b[^>]*?\bhref="([^"]*)"[^>]*>(.*?)</a>',
          caseSensitive: false,
          dotAll: true,
        ),
        (m) {
          final url = m[1]!;
          // 内側の <span> 等を除いた可視ラベル。
          final label = m[2]!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
          // 本物のハッシュタグ / メンション anchor はラベルが単一トークン
          // （`#tag` / `@user@host`、内部空白なし）。これだけを素のテキストへ
          // 戻し、MFM パーサ側で hashtag / mention ノードとして再検出させる
          // (#595)。ラベル先頭がたまたま `#` / `@` でも空白を含むなら実リンクの
          // ラベルなので、href を捨てずリンクとして維持する (#750: pixiv 等の
          // `[#... 文章 ...](url)` 形式リンクが壊れていた)。
          final isSingleToken = !RegExp(r'\s').hasMatch(label);
          if (isSingleToken &&
              (label.startsWith('#') || label.startsWith('@'))) {
            return label;
          }
          // ラベルが空 / URL と同一なら裸の URL にして自動リンクに任せる。
          if (label.isEmpty || label == url) return url;
          return '[$label]($url)';
        },
      )
  // Preserve tags the MFM parser understands: <b>, <i>, <s>, <small>,
  // <center>. Strip only their closing/opening from the "remove all" regex
  // by converting them to placeholders, then restoring after strip.
  ;
  // Protect MFM-compatible tags from the blanket strip.
  const mfmTags = ['b', 'i', 's', 'small', 'center'];
  for (final tag in mfmTags) {
    text = text
        .replaceAll('<$tag>', '\x00$tag\x01')
        .replaceAll('</$tag>', '\x00/$tag\x01');
  }
  // Strip remaining HTML tags
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  // Restore MFM-compatible tags
  for (final tag in mfmTags) {
    text = text
        .replaceAll('\x00$tag\x01', '<$tag>')
        .replaceAll('\x00/$tag\x01', '</$tag>');
  }
  text = _unescape.convert(text);
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
typedef EmojiTapCallback = void Function(String shortcode, String emojiUrl);

/// Synchronous URL resolver: returns the resolved URL or `null`.
typedef LinkLongPressCallback = void Function(String url);
typedef UrlResolver = String? Function(String url);

class ContentRenderer {
  final TextStyle baseStyle;
  final EmojiResolver resolveEmoji;
  final LinkTapCallback? onLinkTap;
  final LinkLongPressCallback? onLinkLongPress;
  final HashtagTapCallback? onHashtagTap;
  final MentionTapCallback? onMentionTap;
  final EmojiTapCallback? onEmojiTap;
  final UrlResolver? resolveUrl;
  final UrlResolver? resolveDisplayUrl;
  final double emojiSize;
  final bool applyNyaize;

  /// MFM のアニメーション構文（`$[bounce]` 等）を再生するか (#259)。false の
  /// ときは従来どおり子要素を静止表示する。呼び出し側が設定
  /// （mfmAnimationEnabledProvider）を渡す。
  final bool animateMfm;
  final List<GestureRecognizer> _recognizers = [];

  ContentRenderer({
    required this.baseStyle,
    required this.resolveEmoji,
    this.onLinkTap,
    this.onLinkLongPress,
    this.onHashtagTap,
    this.onMentionTap,
    this.onEmojiTap,
    this.resolveUrl,
    this.resolveDisplayUrl,
    this.emojiSize = 20.0,
    this.applyNyaize = false,
    this.animateMfm = false,
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
        final text = applyNyaize ? nyaize(node.text) : node.text;
        return _buildTextWithEmoji(text, style);

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
        // 背の高い WidgetSpan の直後に TextSpan('\n') を置くと、その末尾改行が
        // 行の下側にブロック高ぶんの空白を作る (Flutter の WidgetSpan +
        // trailing newline 既知挙動)。末尾 \n は外し、ブロック下の余白は
        // margin で確保する。単独行への隔離は先頭 \n が担う。
        // なお width: double.infinity は iPad で RenderFlex overflow を起こす
        // ため使えない (#60・tech-notes 参照)。自然幅のまま組む。
        return [
          TextSpan(text: '\n', style: style),
          WidgetSpan(
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (node.language != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        node.language!,
                        style: style.copyWith(
                          fontSize: (style.fontSize ?? 14) * 0.75,
                          color: Colors.grey,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  // コードは折り返さず横スクロール (#434)。コマンドトゥート
                  // の結果として表示する JSON / YAML も同じ codeBlock 経路で
                  // 描画されるので、長い 1 行が省略 / 折り返しで読みにくく
                  // ならないようにする。
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      node.text,
                      softWrap: false,
                      style: style.copyWith(
                        fontFamily: 'monospace',
                        fontSize: (style.fontSize ?? 14) * 0.9,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
            // ベース文字のベースラインを周囲テキストに揃える（読みは上に乗る）。
            // _RubyWidget 側で base 行のベースラインが placeholder の
            // baseline として報告されるよう組んでいる（#771）。
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _RubyWidget(
              base: node.text,
              reading: node.rubyReading ?? '',
              baseStyle: style,
            ),
          ),
        ];

      case _NodeType.link:
        final url = node.url ?? '';
        if (onLinkLongPress != null) {
          return [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: () => onLinkTap?.call(url),
                onLongPress: () => onLinkLongPress!.call(url),
                child: Text(
                  node.text,
                  style: style.copyWith(color: Colors.blue),
                ),
              ),
            ),
          ];
        }
        final recognizer = TapGestureRecognizer()
          ..onTap = () => onLinkTap?.call(url);
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
        final originalUrl = node.text;
        final resolvedUrl = resolveUrl?.call(originalUrl) ?? originalUrl;
        final uri =
            Uri.tryParse(resolvedUrl) ??
            Uri.tryParse(Uri.encodeFull(resolvedUrl));
        final customDisplay = resolveDisplayUrl?.call(originalUrl);
        final displayUrl =
            customDisplay ??
            (uri != null
                ? _shortenUrl(Uri.decodeFull(uri.toString()))
                : resolvedUrl);
        // ベタ貼り URL も onLinkTap 経由にする (#820)。fediverse の投稿/アカウント
        // URL はアプリ内スレッド/プロフィールへ resolve され、それ以外はハンドラ側
        // でブラウザに落ちる。onLinkTap 未指定の呼び出し元では従来どおり直接開く。
        void Function()? handleTap;
        if (onLinkTap != null) {
          handleTap = () => onLinkTap!.call(resolvedUrl);
        } else if (uri != null) {
          handleTap = () => launchUrlSafely(uri);
        }
        if (onLinkLongPress != null && handleTap != null) {
          return [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: handleTap,
                onLongPress: () => onLinkLongPress!.call(resolvedUrl),
                child: Text(
                  displayUrl,
                  style: style.copyWith(color: Colors.blue),
                ),
              ),
            ),
          ];
        }
        final recognizer = TapGestureRecognizer()..onTap = handleTap;
        _recognizers.add(recognizer);
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
          final image = ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: emojiSize,
              maxWidth: emojiSize * 3,
            ),
            child: Image.network(
              emojiUrl,
              height: emojiSize,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  Text(':${node.text}:', style: const TextStyle(fontSize: 14)),
            ),
          );
          return [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: onEmojiTap != null
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onEmojiTap!(node.text, emojiUrl),
                      child: image,
                    )
                  : image,
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
        return _renderFn(node, style);
    }
  }

  /// Parse a `key=value` arg from the fn args string.
  static String? _fnArg(String? args, String key) {
    if (args == null) return null;
    // Args may be comma-separated: "color=ff0000,size=2x"
    for (final part in args.split(',')) {
      final eq = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq).trim() == key) {
        return part.substring(eq + 1).trim();
      }
    }
    return null;
  }

  /// `.h,v` のようなキー無しフラグの有無を返す (#748: flip 等)。
  static bool _fnFlag(String? args, String flag) {
    if (args == null) return false;
    for (final part in args.split(',')) {
      if (part.trim() == flag) return true;
    }
    return false;
  }

  /// MFM 引数値を double に変換する (#748: rotate/scale/position/border)。
  static double? _parseNum(String? s) =>
      s == null ? null : double.tryParse(s.trim());

  /// 2 桁ゼロ埋め (#748: unixtime の日時表記)。
  static String _two(int n) => n.toString().padLeft(2, '0');

  /// ノード木を素のテキストに畳む (#748: unixtime のタイムスタンプ取得)。
  static String _collectText(List<_Node> nodes) {
    final buf = StringBuffer();
    for (final n in nodes) {
      buf.write(n.text);
      if (n.children.isNotEmpty) buf.write(_collectText(n.children));
    }
    return buf.toString();
  }

  /// Try to parse a hex color string (with or without leading #).
  static Color? _parseHexColor(String hex) {
    hex = hex.replaceFirst('#', '');
    if (hex.length == 3) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    return value != null ? Color(value) : null;
  }

  List<InlineSpan> _renderFn(_Node node, TextStyle style) {
    switch (node.fnName) {
      case 'fg':
        final color = _parseHexColor(_fnArg(node.fnArgs, 'color') ?? '');
        if (color != null) {
          return _renderNodes(node.children, style.copyWith(color: color));
        }
        return _renderNodes(node.children, style);

      case 'bg':
        final color = _parseHexColor(_fnArg(node.fnArgs, 'color') ?? '');
        if (color != null) {
          return _renderNodes(
            node.children,
            style.copyWith(backgroundColor: color),
          );
        }
        return _renderNodes(node.children, style);

      case 'font':
        // $[font.serif ...], $[font.monospace ...], etc.
        final family = node.fnArgs; // args is the font family name
        if (family != null && family.isNotEmpty) {
          return _renderNodes(
            node.children,
            style.copyWith(fontFamily: family),
          );
        }
        return _renderNodes(node.children, style);

      case 'blur':
        return [
          WidgetSpan(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Text.rich(
                TextSpan(children: _renderNodes(node.children, style)),
              ),
            ),
          ),
        ];

      case 'flip':
        // 反転 (#748)。引数なし / `.h` は水平、`.v` は垂直、`.h,v` は両方
        // （180° 回転相当）。アニメーションではないので静的に対応。
        final noArgs = node.fnArgs == null || node.fnArgs!.isEmpty;
        final scaleX = (_fnFlag(node.fnArgs, 'h') || noArgs) ? -1.0 : 1.0;
        final scaleY = _fnFlag(node.fnArgs, 'v') ? -1.0 : 1.0;
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(scaleX, scaleY, 1.0),
              child: Text.rich(
                TextSpan(children: _renderNodes(node.children, style)),
              ),
            ),
          ),
        ];

      case 'rotate':
        // 回転 (#748)。`.deg=<角度>`、既定 90 度、時計回り。
        final deg = _parseNum(_fnArg(node.fnArgs, 'deg')) ?? 90;
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Transform.rotate(
              angle: deg * math.pi / 180,
              child: Text.rich(
                TextSpan(children: _renderNodes(node.children, style)),
              ),
            ),
          ),
        ];

      case 'scale':
        // 拡大縮小 (#748)。`.x=<倍率>,y=<倍率>`、既定 1。本家に倣い 0〜5 に
        // クランプ（暴走した巨大表示を防ぐ）。
        final sx = (_parseNum(_fnArg(node.fnArgs, 'x')) ?? 1).clamp(0.0, 5.0);
        final sy = (_parseNum(_fnArg(node.fnArgs, 'y')) ?? 1).clamp(0.0, 5.0);
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Transform.scale(
              scaleX: sx,
              scaleY: sy,
              child: Text.rich(
                TextSpan(children: _renderNodes(node.children, style)),
              ),
            ),
          ),
        ];

      case 'position':
        // 平行移動 (#748)。`.x=<em>,y=<em>`。em ≒ フォントサイズとして換算。
        final fs = style.fontSize ?? 14.0;
        final px = (_parseNum(_fnArg(node.fnArgs, 'x')) ?? 0) * fs;
        final py = (_parseNum(_fnArg(node.fnArgs, 'y')) ?? 0) * fs;
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Transform.translate(
              offset: Offset(px, py),
              child: Text.rich(
                TextSpan(children: _renderNodes(node.children, style)),
              ),
            ),
          ),
        ];

      case 'border':
        // 枠線 (#748)。`.width=<n>,style=<solid|...>,color=<hex>,radius=<n>`。
        // Flutter の BoxBorder は実線のみのため dotted/dashed/double も実線で
        // 代替する（`noclip` は Flutter 側で既定クリップしないため無視）。
        final bw = (_parseNum(_fnArg(node.fnArgs, 'width')) ?? 1).toDouble();
        final radius = (_parseNum(_fnArg(node.fnArgs, 'radius')) ?? 0)
            .toDouble();
        final borderColor =
            _parseHexColor(_fnArg(node.fnArgs, 'color') ?? '') ??
            style.color ??
            const Color(0xFF888888);
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                border: Border.all(color: borderColor, width: bw),
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Text.rich(
                TextSpan(children: _renderNodes(node.children, style)),
              ),
            ),
          ),
        ];

      case 'unixtime':
        // Unix 時刻（秒）を端末ローカルの日時表記に変換 (#748)。子要素テキストが
        // タイムスタンプ。数値でなければ素通し。
        final raw = _collectText(node.children).trim();
        final secs = int.tryParse(raw);
        if (secs != null) {
          final dt = DateTime.fromMillisecondsSinceEpoch(
            secs * 1000,
          ).toLocal();
          final text =
              '${dt.year}/${_two(dt.month)}/${_two(dt.day)} '
              '${_two(dt.hour)}:${_two(dt.minute)}:${_two(dt.second)}';
          return [TextSpan(text: text, style: style)];
        }
        return _renderNodes(node.children, style);

      case 'x2':
        return _renderNodes(
          node.children,
          style.copyWith(fontSize: (style.fontSize ?? 14) * 2),
        );

      case 'x3':
        return _renderNodes(
          node.children,
          style.copyWith(fontSize: (style.fontSize ?? 14) * 3),
        );

      case 'x4':
        return _renderNodes(
          node.children,
          style.copyWith(fontSize: (style.fontSize ?? 14) * 4),
        );

      case 'spin':
      case 'bounce':
      case 'jump':
      case 'shake':
      case 'twitch':
      case 'jelly':
      case 'tada':
      case 'rainbow':
        // アニメーション構文 (#259)。設定 OFF・非対応環境では静止表示。
        return _renderAnimation(node, style);

      default:
        // Unhandled fn — render children as-is（sparkle 等の未対応も含む）
        return _renderNodes(node.children, style);
    }
  }

  /// MFM アニメーション構文を [MfmAnimation] でラップする (#259)。設定が OFF の
  /// ときは静止表示にフォールバックする。`.speed=` と spin の `.left` を解釈する。
  List<InlineSpan> _renderAnimation(_Node node, TextStyle style) {
    final children = _renderNodes(node.children, style);
    if (!animateMfm) return children;
    final type = switch (node.fnName) {
      'spin' => MfmAnimationType.spin,
      'bounce' => MfmAnimationType.bounce,
      'jump' => MfmAnimationType.jump,
      'shake' => MfmAnimationType.shake,
      'twitch' => MfmAnimationType.twitch,
      'jelly' => MfmAnimationType.jelly,
      'tada' => MfmAnimationType.tada,
      'rainbow' => MfmAnimationType.rainbow,
      _ => null,
    };
    if (type == null) return children;
    return [
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: MfmAnimation(
          type: type,
          speed: _parseDuration(_fnArg(node.fnArgs, 'speed')),
          reverse: _fnFlag(node.fnArgs, 'left'),
          fontSize: style.fontSize ?? 14.0,
          child: Text.rich(TextSpan(children: children)),
        ),
      ),
    ];
  }

  /// `1.5s` / `500ms` 形式の MFM speed 引数を Duration に変換する (#259)。
  static Duration? _parseDuration(String? s) {
    if (s == null) return null;
    final v = s.trim();
    if (v.endsWith('ms')) {
      final n = double.tryParse(v.substring(0, v.length - 2));
      return n == null ? null : Duration(milliseconds: n.round());
    }
    if (v.endsWith('s')) {
      final n = double.tryParse(v.substring(0, v.length - 1));
      return n == null ? null : Duration(milliseconds: (n * 1000).round());
    }
    return null;
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
            '${AppConstants.twemojiBaseUrl}/$codepoints.png',
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

  static const _maxPathLength = 20;

  /// Shorten a URL for display: strip scheme, truncate path.
  static String _shortenUrl(String url) {
    // Remove scheme (https://, http://)
    var shortened = url.replaceFirst(RegExp(r'^https?://'), '');
    // Remove trailing slash if it's the only path
    if (shortened.endsWith('/') &&
        !shortened.substring(0, shortened.length - 1).contains('/')) {
      shortened = shortened.substring(0, shortened.length - 1);
    }
    // Truncate long path portion
    final slashIndex = shortened.indexOf('/');
    if (slashIndex >= 0 && shortened.length - slashIndex > _maxPathLength) {
      shortened =
          '${shortened.substring(0, slashIndex + _maxPathLength)}\u2026';
    }
    return shortened;
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
    // base を子リストの先頭に置きつつ verticalDirection.up で視覚上は下段に配置する。
    // Column（RenderFlex）は「子リスト先頭の子」のベースラインを placeholder の
    // baseline として報告するため（defaultComputeDistanceToFirstActualBaseline）、
    // これで base 行のベースラインが周囲テキストに揃い、読みがその上に乗る（#771）。
    return Column(
      mainAxisSize: MainAxisSize.min,
      verticalDirection: VerticalDirection.up,
      children: [
        Text(base, style: baseStyle.copyWith(height: 1)),
        Text(
          reading,
          style: baseStyle.copyWith(fontSize: readingSize, height: 1),
        ),
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
  // 最後の <p> ブロックのみを対象にする（URL 段落を跨がないよう制約）。
  final pBlocks = RegExp(r'<p>.*?</p>').allMatches(bodyHtml).toList();
  if (pBlocks.isEmpty) return (body: bodyHtml, trailingTags: trailingTags);
  final lastPMatch = pBlocks.last;
  final lastBlock = lastPMatch.group(0)!;
  final trailingTagBlock = RegExp(
    r'^<p>\s*((<a[^>]*>.*?</a>\s*)+)</p>$',
    caseSensitive: false,
  );
  final blockMatch = trailingTagBlock.firstMatch(lastBlock);
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
      bodyHtml = bodyHtml.substring(0, lastPMatch.start).trimRight();
    }
  }

  return (body: bodyHtml, trailingTags: trailingTags);
}
