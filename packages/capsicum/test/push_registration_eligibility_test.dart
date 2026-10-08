import 'package:capsicum/src/service/push_registration_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// relay へ登録を試みるかの判定 (#597 / #1181)。
///
/// ⚠⚠ **回帰の本体はここ。**以前は「プリセットのアカウントを 1 つでも持って
/// いるか」だけで閉じていたので、**プリセットを持たない購入者は `/register` に
/// 一度も到達せず、購入が丸ごと死んでいた。**relay 側は「来た要求をどう扱うか」
/// しか見ていないので、**要求が来ないことは向こうからは見えない。**
///
/// ⚠ **ここで固定したいのは 3 点。**
///
/// 1. ⚠⚠ **利用権を持っていれば非プリセットでも試みる**（#1181 が直したもの）
/// 2. ⚠ **プリセットのみ / 利用権なしの利用者の挙動は 1mm も変わらない**
/// 3. ⚠ 判定は 3 つの OR で、**どれか 1 つでも真なら試みる**
void main() {
  const preset = 'mstdn.b-shock.org';
  const external = 'fedibird.com';

  bool decide({
    String host = external,
    bool eligible = false,
    bool hasEntitlement = false,
  }) => PushRegistrationService.shouldAttemptRegistration(
    host: host,
    eligible: eligible,
    hasEntitlement: hasEntitlement,
  );

  group('#1181 利用権を持つ購入者が登録へ到達する', () {
    // ⚠⚠ **これが直した穴そのもの。**
    test('非プリセット + プリセット未所持 + 利用権あり → 試みる', () {
      expect(decide(hasEntitlement: true), isTrue);
    });

    test('非プリセット + プリセット未所持 + 利用権なし → 従来どおり試みない', () {
      expect(decide(), isFalse);
    });
  });

  group('従来の経路は変わらない', () {
    test('プリセットのアカウントは利用権が無くても試みる', () {
      expect(decide(host: preset), isTrue);
    });

    // 「プリセットに 1 アカウント持てば全部無償」の穴は**完全に意図通り**で残す
    // （設計書 1-2 / 未決事項 3）。
    test('プリセットを 1 つ持っていれば外部アカウントも連れて登録する', () {
      expect(decide(eligible: true), isTrue);
    });

    test('プリセット判定は完全一致（サブドメインは別ホスト）', () {
      expect(decide(host: 'evil.$preset'), isFalse);
      expect(decide(host: 'st2.mstdn.b-shock.org'), isTrue);
    });
  });

  group('判定の形', () {
    // ⚠ 3 つの条件はどれも単独で成立する（AND になっていない）。
    test('どれか 1 つでも真なら試みる', () {
      expect(decide(host: preset), isTrue);
      expect(decide(eligible: true), isTrue);
      expect(decide(hasEntitlement: true), isTrue);
      expect(
        decide(host: preset, eligible: true, hasEntitlement: true),
        isTrue,
      );
    });

    // ⚠⚠ **空振りしないことの確認。**全部偽のときだけ偽になる。
    test('全部偽のときだけ試みない', () {
      expect(decide(), isFalse);
    });
  });
}
