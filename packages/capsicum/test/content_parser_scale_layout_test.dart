import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// #876: `$[scale]` の等倍（x==y）は fontSize 倍化でレイアウト寸法ごと拡大する。
///
/// Transform.scale は塗りだけ拡大してレイアウトの占有ボックスを変えないため、
/// 拡大した中身が予約幅を超えて食み出し見切れる（rotate と同型）。等倍は fontSize を
/// 掛けると占有ボックスも一緒に大きくなり食み出さない（`$[x2]` 系と同じ）。非等倍
/// （x≠y）は fontSize では表現できないため従来どおり Transform.scale（＝WidgetSpan）。
void main() {
  ContentRenderer buildRenderer() => ContentRenderer(
    baseStyle: const TextStyle(fontSize: 14),
    resolveEmoji: (_) => null,
  );

  // InlineSpan ツリーを平坦化する（WidgetSpan の子は widget なので辿らない）。
  Iterable<InlineSpan> flatten(InlineSpan span) sync* {
    yield span;
    if (span is TextSpan) {
      for (final child in span.children ?? const <InlineSpan>[]) {
        yield* flatten(child);
      }
    }
  }

  test(r'$[scale.x=2,y=2 ...]（等倍）は fontSize 倍化で表現し WidgetSpan を作らない', () {
    final renderer = buildRenderer();
    addTearDown(renderer.dispose);

    final spans = flatten(renderer.renderMfm(r'$[scale.x=2,y=2 ABC]')).toList();

    // 基準 14 × 2 = 28 の TextSpan が現れる（＝レイアウトごと拡大している）。
    expect(
      spans.whereType<TextSpan>().any((s) => s.style?.fontSize == 28.0),
      isTrue,
    );
    // 等倍は塗りのみ拡大の Transform.scale（WidgetSpan）を経由しない。
    expect(spans.any((s) => s is WidgetSpan), isFalse);
  });

  test(r'$[scale.x=2,y=1 ...]（非等倍）は Transform.scale（WidgetSpan）に退避', () {
    final renderer = buildRenderer();
    addTearDown(renderer.dispose);

    final spans = flatten(renderer.renderMfm(r'$[scale.x=2,y=1 ABC]')).toList();

    expect(spans.any((s) => s is WidgetSpan), isTrue);
    // fontSize は倍化されない（塗りだけ拡大するため基準のまま）。
    expect(
      spans.whereType<TextSpan>().any((s) => s.style?.fontSize == 28.0),
      isFalse,
    );
  });
}
