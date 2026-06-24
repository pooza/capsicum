import 'package:capsicum/src/ui/screen/compose_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

Post _post(String id, {Post? quote}) => Post(
  id: id,
  postedAt: DateTime.utc(2026, 1, 1),
  author: User(id: 'u$id', username: 'u$id'),
  quote: quote,
);

void main() {
  group('resolveComposeQuote — 引用元の解決 (#756)', () {
    test('新規引用 (quoteTo) を最優先する', () {
      final quoteTo = _post('1');
      expect(resolveComposeQuote(quoteTo, null), same(quoteTo));
    });

    test('REPRO: 引用付き投稿の redraft は redraft.quote を引き継ぐ', () {
      final quoted = _post('q');
      final redraft = _post('orig', quote: quoted);
      expect(resolveComposeQuote(null, redraft), same(quoted));
    });

    test('引用なしの redraft は null（通常投稿として再編集）', () {
      final redraft = _post('orig');
      expect(resolveComposeQuote(null, redraft), isNull);
    });

    test('quoteTo と redraft が両方ある場合も quoteTo を優先', () {
      final quoteTo = _post('1');
      final redraft = _post('orig', quote: _post('q'));
      expect(resolveComposeQuote(quoteTo, redraft), same(quoteTo));
    });

    test('どちらも無ければ null', () {
      expect(resolveComposeQuote(null, null), isNull);
    });
  });
}
