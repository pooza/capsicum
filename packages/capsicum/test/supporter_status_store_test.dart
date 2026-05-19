import 'package:capsicum/src/service/supporter_status_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('SupporterRecord (#428 B-3)', () {
    test('empty は未サポーター', () {
      expect(SupporterRecord.empty.isSupporter, isFalse);
      expect(SupporterRecord.empty.tipCount, 0);
    });

    test('firstTippedAt があれば生涯サポーター', () {
      final r = SupporterRecord(firstTippedAt: DateTime(2026, 5, 20));
      expect(r.isSupporter, isTrue);
    });

    test('copyWith は firstTippedAt を維持できる（生涯バッジ不変条件）', () {
      final first = DateTime(2026, 5, 20);
      final r = SupporterRecord(
        firstTippedAt: first,
        tipCount: 1,
      ).copyWith(tipCount: 2, lastSku: 'supporter.tip.large');
      expect(r.firstTippedAt, first);
      expect(r.tipCount, 2);
      expect(r.lastSku, 'supporter.tip.large');
      expect(r.isSupporter, isTrue);
    });
  });

  group('LocalSupporterStatusStore (#428 v1.27)', () {
    test('初期状態は empty 相当（未投げ銭）', () async {
      final store = LocalSupporterStatusStore();
      final r = await store.load();
      expect(r.isSupporter, isFalse);
      expect(r.tipCount, 0);
      expect(r.lastSku, isNull);
      expect(r.syncedToServer, isFalse);
    });

    test('save → load で全フィールドが往復する', () async {
      final store = LocalSupporterStatusStore();
      final at = DateTime.fromMillisecondsSinceEpoch(1_747_700_000_000);
      await store.save(
        SupporterRecord(
          firstTippedAt: at,
          tipCount: 3,
          lastSku: 'supporter.tip.medium',
        ),
      );

      final r = await store.load();
      expect(r.firstTippedAt, at);
      expect(r.tipCount, 3);
      expect(r.lastSku, 'supporter.tip.medium');
      expect(r.isSupporter, isTrue);
      expect(r.syncedToServer, isFalse);
    });

    test('再投げ銭しても初回時刻を維持し回数だけ増える（markTipped 相当の不変条件）', () async {
      final store = LocalSupporterStatusStore();
      final first = DateTime.fromMillisecondsSinceEpoch(1_747_700_000_000);

      // 初回投げ銭
      var current = (await store.load());
      current = current.copyWith(
        firstTippedAt: current.firstTippedAt ?? first,
        tipCount: current.tipCount + 1,
        lastSku: 'supporter.tip.small',
      );
      await store.save(current);

      // 再投げ銭（別 SKU・後の時刻でも firstTippedAt は据え置き）
      current = await store.load();
      current = current.copyWith(
        firstTippedAt:
            current.firstTippedAt ??
            DateTime.fromMillisecondsSinceEpoch(1_747_799_999_000),
        tipCount: current.tipCount + 1,
        lastSku: 'supporter.tip.large',
      );
      await store.save(current);

      final r = await store.load();
      expect(r.firstTippedAt, first);
      expect(r.tipCount, 2);
      expect(r.lastSku, 'supporter.tip.large');
    });
  });
}
