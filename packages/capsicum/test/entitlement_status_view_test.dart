import 'package:capsicum/src/provider/entitlement_status_provider.dart';
import 'package:capsicum/src/ui/screen/settings/push_notification_settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 利用権の見え方 (#597 / #1123)。
///
/// ⚠⚠ **relay が返す文字列を UI で直接比べない**ための畳み込み。`status` は
/// relay 側の語彙で、⚠ **増えることがある**（capsicum-relay#63 が状態を足す）。
void main() {
  group('entitlementViewOf', () {
    test('手元に何も無ければ absent', () {
      expect(entitlementViewOf(null), EntitlementView.absent);
      expect(entitlementViewOf(''), EntitlementView.absent);
    });

    test('active は active', () {
      expect(entitlementViewOf('active'), EntitlementView.active);
    });

    // ⚠ relay がまだ検証できていない状態。⚠⚠ **クライアントは止めない**
    // （判定は relay の仕事・#1121）ので、使える側に置く。
    test('unverified も使える側（判定は relay の仕事）', () {
      expect(entitlementViewOf('unverified'), EntitlementView.active);
    });

    // ⚠⚠ **止まっていないが放っておくと止まる。**気づける形にするため、
    // active と同じ扱いにしない。
    test('猶予・課金リトライは grace', () {
      expect(entitlementViewOf('grace'), EntitlementView.grace);
      expect(entitlementViewOf('billing_retry'), EntitlementView.grace);
    });

    test('失効・返金は expired', () {
      expect(entitlementViewOf('expired'), EntitlementView.expired);
      expect(entitlementViewOf('revoked'), EntitlementView.expired);
    });

    // ⚠⚠ **これがこの関数の存在理由。**知らない値で「未購入」に落ちると、
    // **買った人に「買ってください」と出す** —— 二重購入を誘う取り返しの
    // つかない誤案内になる。失効を見逃すほうは relay 側のゲートが実際に
    // 止めるので必ず気づく。
    test('知らない値は使える側へ倒す（買った人に買わせない）', () {
      expect(entitlementViewOf('some_future_state'), EntitlementView.active);
      expect(entitlementViewOf('ON_HOLD'), EntitlementView.active);
    });

    test('大文字小文字を問わない', () {
      expect(entitlementViewOf('EXPIRED'), EntitlementView.expired);
      expect(entitlementViewOf('Grace'), EntitlementView.grace);
    });
  });

  // relay が返す判定で補正する (#1123・capsicum-relay#63)。
  //
  // ⚠⚠ **`status` だけだと relay と違う結論になる。**relay はゲートで
  // `expires_at` も見るようになったので、「猶予＝まだ届く」「active のまま
  // 期限切れ＝有効」はどちらも**嘘になった**。
  group('entitlementViewOfRelay', () {
    test('reason が無ければ従来どおり status で決める（古い relay 対策）', () {
      expect(
        entitlementViewOfRelay(status: 'active', reason: null),
        EntitlementView.active,
      );
      expect(
        entitlementViewOfRelay(status: 'grace', reason: null),
        EntitlementView.grace,
      );
    });

    // ⚠⚠ 2026-10-03 に「未払いの間は通さない」と決まった。
    test('unpaid は grace（通知は止まっている）', () {
      expect(
        entitlementViewOfRelay(status: 'grace', reason: 'unpaid'),
        EntitlementView.grace,
      );
    });

    // 🔴 **これが status だけでは拾えない形。**更新の通知を取りこぼすと
    // 行は `active` のまま残るので、relay が期限で落としていることが見えない。
    test('🔴 active のまま期限切れ（reason=expired）は expired に倒す', () {
      expect(
        entitlementViewOfRelay(status: 'active', reason: 'expired'),
        EntitlementView.expired,
      );
    });

    // ⚠⚠ **`no_entitlement` を「未購入」に倒さない。**relay は未検証の購入
    // （`unverified`）にもこの理由を返すので、倒すと**買った人に「買って
    // ください」と出す** —— 二重購入は取り返しがつかない。
    test('🔴 no_entitlement では未購入に倒さない（unverified を巻き込むため）', () {
      expect(
        entitlementViewOfRelay(status: 'unverified', reason: 'no_entitlement'),
        EntitlementView.active,
      );
    });

    test('知らない reason は status 側の判断に任せる', () {
      expect(
        entitlementViewOfRelay(status: 'active', reason: 'some_future_reason'),
        EntitlementView.active,
      );
      expect(
        entitlementViewOfRelay(status: 'expired', reason: 'some_future_reason'),
        EntitlementView.expired,
      );
    });

    // 🔴 **relay は通すのに「失効」と出ていた形**（2026-10-03 に発見）。
    // `revoked` は status 側では失効なので、補正しないと**届いているのに
    // 「届かなくなります」と案内する**ことになる。
    test('🔴 entitled_refunded は refunded（relay は通している）', () {
      expect(
        entitlementViewOfRelay(status: 'revoked', reason: 'entitled_refunded'),
        EntitlementView.refunded,
      );
    });

    // ⚠⚠ **`reason` が無い回に「まだ使えます」と言わない。**期間が残っているかを
    // 知っているのは `expires_at` を見た relay だけなので、古い relay に対しては
    // 失効側へ倒したままにする。
    test('⚠ reason が無ければ revoked は失効のまま（refunded に倒さない）', () {
      expect(
        entitlementViewOfRelay(status: 'revoked', reason: null),
        EntitlementView.expired,
      );
    });

    test('大文字小文字を問わない', () {
      expect(
        entitlementViewOfRelay(status: 'active', reason: 'UNPAID'),
        EntitlementView.grace,
      );
      expect(
        entitlementViewOfRelay(status: 'revoked', reason: 'Entitled_Refunded'),
        EntitlementView.refunded,
      );
    });
  });

  // ⚠⚠ **relay は UTC を `2026-11-03 12:34:56` の形で返す**（印が無い）。
  // ⚠ `DateTime.parse` はこれをローカル時刻として読むので、**JST では 9 時間
  // ずれる** —— 日付だけ出す画面では、境目の時刻で 1 日ずれて見える。
  group('formatEntitlementExpiry', () {
    // ⚠⚠ **この検査の歯は「端末のオフセットが 0 でないとき」だけ効く。**
    // UTC で走らせると、ローカル解釈と UTC 解釈の結果が一致してしまうので
    // **ずれを検出できない**（CI は UTC の可能性がある）。⚠ 手元（JST）で
    // 落ちることは確認済み。**「CI が緑だから正しい」と読まないこと。**
    test('印の無い値を UTC として読み、ローカルの日付で出す', () {
      final local = DateTime.utc(2026, 11, 3, 20).toLocal();
      final expected =
          '${local.year}-${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
      expect(formatEntitlementExpiry('2026-11-03 20:00:00'), expected);
    });

    test('印が付いている形はそのまま解釈する', () {
      expect(formatEntitlementExpiry('2026-11-03T20:00:00Z'), isNotNull);
      expect(formatEntitlementExpiry('2026-11-03T20:00:00+09:00'), isNotNull);
    });

    // ⚠ 生の文字列や null を画面に出さないための口。
    test('読めない値は null（文面から日付を落とす）', () {
      expect(formatEntitlementExpiry(null), isNull);
      expect(formatEntitlementExpiry(''), isNull);
      expect(formatEntitlementExpiry('   '), isNull);
      expect(formatEntitlementExpiry('まだ有効'), isNull);
    });
  });

  group('EntitlementStatus.copyWith', () {
    test('expiresAt は省略時に維持される', () {
      const s = EntitlementStatus(
        view: EntitlementView.active,
        expiresAt: '2026-10-28',
      );
      expect(s.copyWith(isRefreshing: false).expiresAt, '2026-10-28');
    });

    test('expiresAt は明示的な null でクリアできる', () {
      const s = EntitlementStatus(expiresAt: '2026-10-28');
      expect(s.copyWith(expiresAt: null).expiresAt, isNull);
    });
  });

  // ⚠⚠ **#1123 の完了条件の 3 つ目。**プリセットのみのユーザーに表示が増えない。
  group('showEntitlementSection', () {
    test('🔴 プリセットのアカウントがあれば、どの状態でも出さない', () {
      for (final view in EntitlementView.values) {
        expect(
          showEntitlementSection(
            hasPreset: true,
            view: view,
            isRefreshing: false,
          ),
          isFalse,
          reason: '$view でも出してはいけない',
        );
      }
    });

    test('非プリセットなら出す', () {
      expect(
        showEntitlementSection(
          hasPreset: false,
          view: EntitlementView.active,
          isRefreshing: false,
        ),
        isTrue,
      );
      // ⚠ 返金済みも出す。**届いているが期限がある**ので、期限を見せる先が要る。
      expect(
        showEntitlementSection(
          hasPreset: false,
          view: EntitlementView.refunded,
          isRefreshing: false,
        ),
        isTrue,
      );
    });

    // ⚠⚠ 一瞬でも「買ってください」と見せると、買った人に二重購入をさせうる。
    test('読み込み中に「未購入」を出さない', () {
      expect(
        showEntitlementSection(
          hasPreset: false,
          view: EntitlementView.absent,
          isRefreshing: true,
        ),
        isFalse,
      );
    });

    // ⚠ 圏外で画面が空になるほうが困る（この画面は不達の切り分けの入口）。
    test('手元に状態があれば、問い合わせ中でも出す', () {
      expect(
        showEntitlementSection(
          hasPreset: false,
          view: EntitlementView.expired,
          isRefreshing: true,
        ),
        isTrue,
      );
    });
  });
}
