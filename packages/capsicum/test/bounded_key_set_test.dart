import 'package:capsicum/src/service/bounded_key_set.dart';
import 'package:flutter_test/flutter_test.dart';

/// #960 / #983 / #982: 表示済み dedup の上限運用。
///
/// ⚠ **全消しに戻すと壊れる**。直前まで覚えていたキーまで一斉に失うので、
/// 遅れて届いた同一通知が「未出」と判定されて二重表示になる（dispatcher）／
/// 掃除対象と分からず通知センターに残骸が残る（cleaner）。
///
/// macOS ネイティブ側の対応物は `macos/Runner/NotificationDedupPlugin.swift`。
/// **挙動を揃える**ので、片方だけ LRU にしない。
void main() {
  test('上限まではすべて覚えている', () {
    final set = BoundedKeySet('t', 3);
    for (final k in ['a', 'b', 'c']) {
      expect(set.add(k), isTrue);
    }
    expect(set.length, 3);
    expect(set.dropped, 0);
    for (final k in ['a', 'b', 'c']) {
      expect(set.contains(k), isTrue);
    }
  });

  test('上限を超えたら最古から 1 件ずつ押し出す（全消しでない）', () {
    final set = BoundedKeySet('t', 3);
    for (final k in ['a', 'b', 'c', 'd']) {
      set.add(k);
    }
    expect(set.contains('a'), isFalse, reason: '最古が押し出される');
    // ⚠ ここが全消しとの分かれ目。直近のキーが残っていること。
    expect(set.contains('b'), isTrue);
    expect(set.contains('c'), isTrue);
    expect(set.contains('d'), isTrue);
    expect(set.length, 3);
    expect(set.dropped, 1);
  });

  test('参照しても位置は変わらない（LRU ではなく FIFO）', () {
    final set = BoundedKeySet('t', 3);
    for (final k in ['a', 'b', 'c']) {
      set.add(k);
    }
    // 'a' を触っても若返らない。
    expect(set.contains('a'), isTrue);
    set.add('d');
    expect(set.contains('a'), isFalse);
  });

  test('既知のキーの再追加は false を返し、押し出しも起こさない', () {
    final set = BoundedKeySet('t', 3);
    expect(set.add('a'), isTrue);
    expect(set.add('a'), isFalse);
    expect(set.length, 1);
    expect(set.dropped, 0);
  });

  test('isEmpty は中身に追随する', () {
    final set = BoundedKeySet('t', 2);
    expect(set.isEmpty, isTrue);
    set.add('a');
    expect(set.isEmpty, isFalse);
  });
}
