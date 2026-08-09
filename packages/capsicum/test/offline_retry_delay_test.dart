import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// #938 の回帰テスト。
///
/// **眼目は「打ち切らない」こと。** #792 の背景再試行は 2/5/15/30 秒の 4 回・
/// 計 52 秒で終了し、以降の自動トリガが一切無かったため、接続が戻っても画面を
/// 開いたまま待っていてもタイムラインへ復帰しなかった。#917 でこの画面が
/// **端末側オフラインでも出る**と分かった以上、52 秒で諦める形は
/// 「最も出やすい状況でこそ効かない」ことを意味する。
///
/// 上限を再導入する変更（例: ramp-up の要素数で打ち切る）が入ると、ここの
/// 「何回目でも値を返す」が壊れる。
void main() {
  group('offlineRetryDelay (#938)', () {
    test('立ち上がりは 2 / 5 / 15 / 30 秒（#792 の刻みを保つ）', () {
      expect(offlineRetryDelay(0), const Duration(seconds: 2));
      expect(offlineRetryDelay(1), const Duration(seconds: 5));
      expect(offlineRetryDelay(2), const Duration(seconds: 15));
      expect(offlineRetryDelay(3), const Duration(seconds: 30));
    });

    test('立ち上がりの合計は 52 秒（打ち切り時代の全長）', () {
      final total = kOfflineRetryRampUp.reduce((a, b) => a + b);
      expect(total, const Duration(seconds: 52));
    });

    test('立ち上がり後は定常間隔へ移る', () {
      expect(offlineRetryDelay(4), kOfflineRetrySteadyInterval);
      expect(offlineRetryDelay(5), kOfflineRetrySteadyInterval);
    });

    test('⚠ 何回目でも必ず値を返す（＝ループが終わらない）', () {
      for (final attempt in [10, 100, 10000, 1 << 30]) {
        expect(
          offlineRetryDelay(attempt),
          kOfflineRetrySteadyInterval,
          reason: '$attempt 回目で打ち切られている',
        );
      }
    });

    test('定常間隔は立ち上がりの最長より短くしない（probe を増やさない）', () {
      expect(
        kOfflineRetrySteadyInterval >= kOfflineRetryRampUp.last,
        isTrue,
        reason: '定常間隔が立ち上がりより短いと、待つほど probe が増える',
      );
    });
  });
}
