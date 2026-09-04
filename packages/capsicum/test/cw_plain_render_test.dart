import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1068 の回帰テスト。
///
/// CW（警告文）を本文と同じ導線でレンダリングするために足した
/// [ContentRenderer.renderPlain] の挙動を固定する。
///
/// ⚠⚠ **Mastodon の `spoiler_text` はプレーンテキスト、Misskey の `cw` は MFM。**
/// 一律 `renderMfm` に通すと Mastodon 側の CW で `**〜**` や `*` が意図せず
/// 装飾される。かといって素の [Text] に戻すとハッシュタグが押せない。
/// **装飾は解釈せず、リンク化と絵文字だけを拾う**のが `renderPlain`。

/// span 木を平文へ畳む（装飾が付いても文字は残るので、文字列比較では
/// 「装飾されたか」を見られない。装飾は style を見る）。
String _flatten(InlineSpan span) {
  final buffer = StringBuffer();
  span.visitChildren((child) {
    if (child is TextSpan && child.text != null) buffer.write(child.text);
    return true;
  });
  return buffer.toString();
}

/// 太字（bold）の span が 1 つでもあるか。
bool _hasBold(InlineSpan span) {
  var found = false;
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.style?.fontWeight == FontWeight.bold) found = true;
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  walk(span);
  return found;
}

/// タップできる span（recognizer 付き）が 1 つでもあるか。
bool _hasTappable(InlineSpan span) {
  var found = false;
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.recognizer != null) found = true;
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  walk(span);
  return found;
}

ContentRenderer _renderer({void Function(String)? onHashtagTap}) =>
    ContentRenderer(
      baseStyle: const TextStyle(),
      resolveEmoji: (_) => null,
      onHashtagTap: onHashtagTap ?? (_) {},
    );

void main() {
  group('ContentRenderer.renderPlain (#1068)', () {
    test('ハッシュタグを押せるようにする', () {
      final span = _renderer().renderPlain('注意 #ネタバレ あり');

      expect(_flatten(span), contains('#ネタバレ'));
      expect(
        _hasTappable(span),
        isTrue,
        reason: 'CW 内のハッシュタグが押せない (#1068 の主目的)',
      );
    });

    test('MFM の装飾構文を解釈しない', () {
      // Mastodon の spoiler_text はプレーンテキストなので、`**` は文字。
      final span = _renderer().renderPlain('**強調ではない**');

      expect(_flatten(span), '**強調ではない**', reason: 'アスタリスクを装飾として食べてしまっている');
      expect(
        _hasBold(span),
        isFalse,
        reason: 'Mastodon の CW で意図しない装飾が付いている (#1068 設計点 3)',
      );
    });

    test('renderMfm では装飾として解釈される（対比）', () {
      // Misskey の cw は MFM なので、こちらは従来どおり装飾してよい。
      final span = _renderer().renderMfm('**強調**');

      expect(_hasBold(span), isTrue);
    });

    test('URL もリンクになる', () {
      final span = _renderer().renderPlain('詳細は https://example.com まで');

      expect(_hasTappable(span), isTrue);
    });

    test('装飾記号だらけでも文字を落とさない', () {
      const input = r'*a* ~~b~~ `c` $[jelly d] <b>e</b>';
      final span = _renderer().renderPlain(input);

      expect(_flatten(span), input, reason: 'plain モードは 1 文字も食べずにそのまま出す');
    });
  });
}
