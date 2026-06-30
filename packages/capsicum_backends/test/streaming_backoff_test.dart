import 'dart:math';

import 'package:capsicum_backends/src/streaming_backoff.dart';
import 'package:test/test.dart';

void main() {
  group('reconnectBackoffMs (#784)', () {
    const base = 1000; // 1s
    const max = 60000; // 60s

    test('初動は速い（attempt 0 は base/2〜base に収まる）', () {
      for (var i = 0; i < 50; i++) {
        final d = reconnectBackoffMs(0, baseMs: base, maxMs: max);
        expect(d, inInclusiveRange(base ~/ 2, base));
      }
    });

    test('指数で伸び、それぞれ computed/2〜computed に収まる', () {
      // computed = clamp(base * 2^attempt, base, max)
      int computed(int attempt) => (base * (1 << attempt)).clamp(base, max);
      for (final attempt in [0, 1, 2, 3, 4, 5]) {
        final c = computed(attempt);
        for (var i = 0; i < 30; i++) {
          final d = reconnectBackoffMs(attempt, baseMs: base, maxMs: max);
          expect(
            d,
            inInclusiveRange(c ~/ 2, c),
            reason: 'attempt=$attempt computed=$c',
          );
        }
      }
    });

    test('上限 max を超えない（大きい attempt でも頭打ち）', () {
      for (final attempt in [10, 20, 100, 1000]) {
        final d = reconnectBackoffMs(attempt, baseMs: base, maxMs: max);
        expect(d, lessThanOrEqualTo(max));
        // max に達したら下限は max/2
        expect(d, greaterThanOrEqualTo(max ~/ 2));
      }
    });

    test('overflow しない（諦めず attempt が増え続けても安全）', () {
      // 1 << attempt の overflow を内部クランプで防ぐ。
      expect(
        () => reconnectBackoffMs(1 << 30, baseMs: base, maxMs: max),
        returnsNormally,
      );
    });

    test('seed 固定の Random で決定的（jitter は範囲内）', () {
      final d1 = reconnectBackoffMs(
        2,
        baseMs: base,
        maxMs: max,
        random: Random(42),
      );
      final d2 = reconnectBackoffMs(
        2,
        baseMs: base,
        maxMs: max,
        random: Random(42),
      );
      expect(d1, d2);
    });
  });
}
