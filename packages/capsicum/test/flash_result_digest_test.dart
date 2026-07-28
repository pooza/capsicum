import 'package:capsicum/src/ui/flash/as_ui.dart';
import 'package:capsicum/src/ui/flash/flash_result_digest.dart';
import 'package:flutter_test/flutter_test.dart';

/// フラットなコンポーネントレジストリから lookup を作る（#830 のツリー構造を模す）。
AsUiComponent? Function(String) _lookup(Map<String, AsUiComponent> registry) =>
    (id) => registry[id];

AsUiComponent _text(String id, String text) =>
    AsUiComponent(id: id, type: 'text', props: {'text': text});

void main() {
  group('playResultDigest (#898)', () {
    test('同じツリーは同じ指紋（安定）', () {
      final registry = {'a': _text('a', 'ヒュンケル')};
      final first = playResultDigest(['a'], _lookup(registry));
      final second = playResultDigest(['a'], _lookup(registry));
      expect(first, second);
    });

    test('テキスト（出目）が変われば指紋も変わる', () {
      final before = playResultDigest([
        'a',
      ], _lookup({'a': _text('a', 'ヒュンケル')}));
      final after = playResultDigest([
        'a',
      ], _lookup({'a': _text('a', 'ラーハルト')}));
      expect(before, isNot(after));
    });

    test('子の順序が変われば指紋も変わる', () {
      final root = AsUiComponent(
        id: 'root',
        type: 'container',
        props: {
          'children': ['a', 'b'],
        },
      );
      final rootSwapped = AsUiComponent(
        id: 'root',
        type: 'container',
        props: {
          'children': ['b', 'a'],
        },
      );
      final registry = {'a': _text('a', 'A'), 'b': _text('b', 'B')};
      final normal = playResultDigest([
        'root',
      ], _lookup({...registry, 'root': root}));
      final swapped = playResultDigest([
        'root',
      ], _lookup({...registry, 'root': rootSwapped}));
      expect(normal, isNot(swapped));
    });

    test('type と text の境界が曖昧にならない（区切りが効く）', () {
      // 区切りが無いと 'text'+'ab' と 'texta'+'b' が衝突しうる。
      final a = playResultDigest(
        ['x'],
        _lookup({
          'x': AsUiComponent(id: 'x', type: 'text', props: {'text': 'ab'}),
        }),
      );
      final b = playResultDigest(
        ['x'],
        _lookup({
          'x': AsUiComponent(id: 'x', type: 'texta', props: {'text': 'b'}),
        }),
      );
      expect(a, isNot(b));
    });

    test('循環参照（子が親を指す）でも停止する', () {
      final a = AsUiComponent(
        id: 'a',
        type: 'container',
        props: {
          'children': ['b'],
        },
      );
      final b = AsUiComponent(
        id: 'b',
        type: 'container',
        props: {
          'children': ['a'], // a に戻る循環
        },
      );
      // 無限ループにならず値を返せること。
      final digest = playResultDigest(['a'], _lookup({'a': a, 'b': b}));
      expect(digest, hasLength(8));
    });
  });

  group('playEmojiInventoryDigest (#898)', () {
    test('件数とカテゴリ別件数を数える', () {
      final digest = playEmojiInventoryDigest([
        (name: 'larhalt_g', category: 'アバンの使徒'),
        (name: 'hyunckel', category: 'アバンの使徒'),
        (name: 'gome', category: null),
      ]);
      expect(digest.count, 3);
      expect(digest.categoryCounts['アバンの使徒'], 2);
      expect(digest.categoryCounts['(none)'], 1);
    });

    test('同じインベントリなら同じハッシュ（安定）', () {
      final emojis = [(name: 'a', category: 'x'), (name: 'b', category: 'y')];
      expect(
        playEmojiInventoryDigest(emojis).hash,
        playEmojiInventoryDigest(emojis).hash,
      );
    });

    test('絵文字が 1 個増えるとハッシュが変わる（版マーカー）', () {
      final before = playEmojiInventoryDigest([(name: 'a', category: 'x')]);
      final after = playEmojiInventoryDigest([
        (name: 'a', category: 'x'),
        (name: 'b', category: 'x'),
      ]);
      expect(before.hash, isNot(after.hash));
      expect(after.count, before.count + 1);
    });

    test('name が同じでも category が変われば（改名/移動）ハッシュが変わる', () {
      final before = playEmojiInventoryDigest([(name: 'a', category: 'x')]);
      final after = playEmojiInventoryDigest([(name: 'a', category: 'z')]);
      expect(before.hash, isNot(after.hash));
    });
  });
}
