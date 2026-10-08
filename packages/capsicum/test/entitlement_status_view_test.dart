import 'dart:io';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/entitlement_status_provider.dart';
import 'package:capsicum/src/service/push_registration_service.dart';
import 'package:capsicum/src/ui/screen/settings/push_notification_settings_screen.dart';
import 'package:capsicum/src/ui/widget/relay_entitlement_purchase_section.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

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

  /// #1232: プリセットの利用者に「利用権がありません／ご購入が必要です」と
  /// 出していた。⚠⚠ `docs/product-policy.md` の不変条件（プリセットの利用者に
  /// は決して課金しない・**課金の状態を見せるだけでも破れる**）に触れる。
  group('⚠⚠ プリセットの利用者に課金の話をしない (#1232)', () {
    (String, String, IconData) copyOf(EntitlementView view) =>
        relayEntitlementStatusCopy(view: view, expiresAt: null);

    test('⚠ プリセットにログイン済みなら、利用権は無条件で「ある」側', () async {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _PresetAccounts([_account('mstdn.b-shock.org')]),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(entitlementStatusProvider);
      // build() の scheduleMicrotask(refresh) を走らせる。
      await Future<void>.delayed(Duration.zero);

      // 🔴 直す前はここが absent だった（「利用権がありません」と出ていた）。
      expect(
        container.read(entitlementStatusProvider).view,
        EntitlementView.preset,
      );
    });

    test('⚠ プリセットが無ければ従来どおり（relay / 手元の保存で決まる）', () async {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _PresetAccounts([_account('example.com')]),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(entitlementStatusProvider);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(entitlementStatusProvider).view,
        isNot(EntitlementView.preset),
      );
    });

    // ⚠⚠ **文字列の一致では書かない。**文面を言い換えた瞬間に歯が抜ける。
    // 「出てはいけない語が出ていないか」で見る。
    test('⚠⚠ プリセットの文面が、課金を促したり「無い」と告げたりしない', () {
      final (title, body, _) = copyOf(EntitlementView.preset);
      final text = '$title$body';

      // ⚠⚠ **「購入」という語ごと出さない。**「購入は必要ありません」も
      // 課金の話を持ち出していることに変わりはない。
      for (final forbidden in ['購入', 'ありません', '失効', '料金', '月額']) {
        expect(
          text.contains(forbidden),
          isFalse,
          reason: '⚠ プリセットの利用者に「$forbidden」と言ってはいけない',
        );
      }
      // 使えていることを言っている。
      expect(text.contains('利用いただけます') || text.contains('届きます'), isTrue);
    });

    // ⚠⚠ 購入ボタンを出すのは「課金を促す」に当たる。
    test('⚠⚠ プリセットの利用者に購入ボタンを出さない', () {
      expect(showRelayPurchaseButton(view: EntitlementView.preset), isFalse);
      // 対照群: 未購入・失効の人には出る（買えなくしたわけではない）。
      expect(showRelayPurchaseButton(view: EntitlementView.absent), isTrue);
      expect(showRelayPurchaseButton(view: EntitlementView.expired), isTrue);
    });

    // 🔴 #1232 は購入ボタンしか消しておらず、「取り直す」「購入を確認して
    // 登録し直す」がプリセットの利用者に出ていた（2026-10-06 に 194 で発見）。
    test('⚠⚠ プリセットの利用者に、復元・記録を消すを出さない', () {
      expect(
        showRelayEntitlementActions(view: EntitlementView.preset),
        isFalse,
      );
      // 対照群: ほかの状態では全部出す。⚠ `absent` でも出すのは、機種変更・
      // 再インストールからの復元の口だから (#1219)。
      for (final view in EntitlementView.values) {
        if (view == EntitlementView.preset) continue;
        expect(
          showRelayEntitlementActions(view: view),
          isTrue,
          reason: '⚠ $view で操作を隠すと、復元・再登録の口が無くなる',
        );
      }
    });

    // ⚠⚠ **判定を足しただけでは効かない。**ウィジェットが呼んでいることを見る
    // （呼ばなくなっても上のテストは緑のまま）。
    test('⚠⚠ 操作と添え書きは、判定を通ってから並ぶ（配線）', () {
      final src = File(
        'lib/src/ui/widget/relay_entitlement_purchase_section.dart',
      ).readAsStringSync();
      final gate = src.indexOf('if (showRelayEntitlementActions(view: view))');
      final restore = src.indexOf("Text('購入を復元する')");
      final forget = src.indexOf("Text('利用権の記録を消す')");
      // ⚠ 添え書きも課金の話なので、プリセットの利用者には出さない。
      final hint = src.indexOf("'お支払いは発生しません。");
      // 空振りしていないこと。
      expect(restore, greaterThan(0));
      expect(forget, greaterThan(0));
      expect(hint, greaterThan(0));
      expect(gate, greaterThan(0), reason: '⚠ 判定がウィジェットに配線されていない');
      // どれも判定の後ろにあること。
      expect(gate, lessThan(restore));
      expect(gate, lessThan(forget));
      expect(gate, lessThan(hint));
      // ⚠ 判定の内側であること: 判定からいちばん遠いものまでの間に、
      // 次の兄弟（解約の案内）が挟まっていない。
      final note = src.indexOf('relayCancellationNote(store:');
      expect(note, greaterThan(forget));
      expect(note, greaterThan(hint));
    });

    // 🔴 以前は全プラットフォームで「ご利用のストア（App Store / Google Play）」と
    // 並べていた。iOS 版に「Google Play」と出すのは App Store の審査指針
    // （ほかのモバイルプラットフォームの名前を出さない）に当たりうる。
    test('⚠⚠ 解約の案内に、ほかのストアの名前を出さない', () {
      final apple = relayCancellationNote(store: 'apple');
      final google = relayCancellationNote(store: 'google');
      final other = relayCancellationNote(store: null);

      expect(apple, contains('App Store'));
      expect(apple, isNot(contains('Google')));
      expect(google, contains('Google Play'));
      expect(google, isNot(contains('App Store')));
      // ⚠ 知らないストアでは、どちらの名前も出さない。
      for (final text in [other, relayCancellationNote(store: 'microsoft')]) {
        expect(text, isNot(contains('App Store')));
        expect(text, isNot(contains('Google')));
      }
      // どの版でも、自動更新であることと解約できることは言う。
      for (final text in [apple, google, other]) {
        expect(text, contains('自動更新'));
        expect(text, contains('解約'));
      }
    });

    test('⚠⚠ 解約の案内は出し分けの関数を通っている（配線）', () {
      final src = File(
        'lib/src/ui/widget/relay_entitlement_purchase_section.dart',
      ).readAsStringSync();

      expect(
        src,
        contains('relayCancellationNote(store: entitlementStoreName())'),
      );
      // 🔴 両方を並べた古い綴りが戻ってきたら落とす。
      expect(src, isNot(contains('App Store / Google Play')));
    });

    // ---- 買っても届かないアカウントを、買う前に知らせる (2026-10-06) ----
    //
    // 🔴 モロヘイヤの中継が無い Misskey は、サーバーソフトウェアの仕様で購読を
    // 登録できない。未購入の人は登録を試みないので、**何も言わないと月額を
    // 払ってから「対応していません」と知る**ことになる。

    test('⚠⚠ モロヘイヤの中継が無い Misskey は「届かない」と判定する', () {
      bool unavailable(BackendType type, {String? controller, String? v}) =>
          PushRegistrationService.pushUnavailableByServerSpec(
            type: type,
            mulukhiyaControllerType: controller,
            mulukhiyaVersion: v,
          );

      // モロヘイヤが無い Misskey。
      expect(unavailable(BackendType.misskey), isTrue);
      // モロヘイヤはあるが、中継（5.19.0〜）より古い。
      expect(
        unavailable(BackendType.misskey, controller: 'misskey', v: '5.18.9'),
        isTrue,
      );
      // 版が読めないときは届かない側（登録処理と同じ倒し方）。
      expect(
        unavailable(BackendType.misskey, controller: 'misskey', v: 'x'),
        isTrue,
      );

      // 対照群: 届くもの。
      expect(
        unavailable(BackendType.misskey, controller: 'misskey', v: '5.19.0'),
        isFalse,
      );
      expect(
        unavailable(BackendType.misskey, controller: 'misskey', v: '6.0.0'),
        isFalse,
      );
      // ⚠⚠ **Mastodon には決して出さない**（モロヘイヤの有無に関係なく届く）。
      expect(unavailable(BackendType.mastodon), isFalse);
      expect(
        unavailable(BackendType.mastodon, controller: 'mastodon', v: '5.0.0'),
        isFalse,
      );
    });

    test('⚠⚠ 届かないアカウントの文面は、名指しして言い切る', () {
      // 該当が無ければ何も出さない。
      expect(relayUnsupportedAccountNote(const []), isNull);

      final one = relayUnsupportedAccountNote(const ['@a@example.test'])!;
      expect(one, contains('@a@example.test'));
      // ⚠ ぼかさない（「場合があります」では、自分が当たるのか分からない）。
      expect(one, contains('届きません'));
      expect(one, isNot(contains('場合があります')));
      expect(one, contains('購入しても'));

      final two = relayUnsupportedAccountNote(const [
        '@a@example.test',
        '@b@example.test',
      ])!;
      expect(two, contains('@a@example.test'));
      expect(two, contains('@b@example.test'));
      expect(two, contains('届きません'));
    });

    test('⚠⚠ 届かないアカウントの注意は節に配線されていて、プリセットには出さない', () {
      final src = File(
        'lib/src/ui/widget/relay_entitlement_purchase_section.dart',
      ).readAsStringSync();

      expect(
        src,
        contains('PushRegistrationService.accountsWithoutPushSupport('),
      );
      expect(src, contains('if (unsupportedNote != null)'));
      // ⚠ プリセットの利用者には購入の話をしない (#1232)。
      final decl = src.indexOf('final unsupportedNote =');
      expect(decl, greaterThan(0));
      expect(
        src.substring(decl, decl + 120),
        contains('view == EntitlementView.preset'),
      );
    });

    // ⚠⚠ **存在しない権限の区分を前提にした説明を消す (#1232)。**
    // 「プリセット以外のサーバーでは受け取れない」は、**プリセットでだけ使える
    // 権利を持っている**という状態を前提にしている。absent が出るのは
    // プリセットを 1 つも持たない人なので、その人にはどのサーバーでも届かない。
    test('⚠ 未購入の文面が「プリセット以外のサーバーで」と言わない', () {
      final (_, body, _) = copyOf(EntitlementView.absent);
      expect(body.contains('プリセット以外'), isFalse);
      expect(body.contains('ご購入が必要'), isTrue, reason: '買えば使えることは言う');
    });
  });
}

/// プリセット判定のためだけのアカウント管理。
class _PresetAccounts extends AccountManagerNotifier {
  _PresetAccounts(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

class _Adapter extends Mock implements DecentralizedBackendAdapter {}

Account _account(String host) => Account(
  key: AccountKey(type: BackendType.mastodon, host: host, username: 'me'),
  adapter: _Adapter(),
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);
