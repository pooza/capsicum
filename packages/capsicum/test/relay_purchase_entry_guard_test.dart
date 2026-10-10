import 'dart:io';

import 'package:capsicum/src/provider/entitlement_status_provider.dart';
import 'package:capsicum/src/provider/supporter_purchase_provider.dart';
import 'package:capsicum/src/ui/widget/relay_entitlement_purchase_section.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1217: プッシュ通知設定画面からも利用権を買えるようにした回の不変条件。
///
/// ⚠⚠ **崩れると「課金の表示が増えてはいけない人に増える」か「買えない入口が
/// 出る」のどちらかになる。**どちらも #1123 の完了条件 3（プリセットのみの人には
/// 何も表示が増えない）と #1122 の「押しても買えない入口を作らない」を壊す。
void main() {
  const pushPath =
      'lib/src/ui/screen/settings/push_notification_settings_screen.dart';
  const supporterPath = 'lib/src/ui/screen/settings/supporter_screen.dart';
  const sectionPath =
      'lib/src/ui/widget/relay_entitlement_purchase_section.dart';

  /// サーバー情報 / プロフィール画面が使う登録状態の共有ウィジェット。
  /// ⚠ **判定を 3 箇所目に書かないため、ここも同時に見る (#1218)。**
  const statusSectionPath =
      'lib/src/ui/widget/push_registration_status_section.dart';

  /// この回より前の綴り（歯の確認に使う）。⚠ **`HEAD` と書かない** —— この回を
  /// コミットすると `HEAD` が新しい綴りに変わり、**穴が開かないので検査が
  /// 自明に通る**ようになる。
  const beforeRev = '0fb0bae3';

  String read(String path) => File(path).readAsStringSync();

  /// `final <name> = ...;` の式だけを切り出す。
  ///
  /// ⚠⚠ **見つからなければ落とす。**名前を変えたならこの検査も直す —— 黙って
  /// 空文字を返すと「門がある」の判定が**何も見ずに通る**。
  String localExpr(String source, String name) {
    final head = 'final $name =';
    final start = source.indexOf(head);
    expect(start, greaterThanOrEqualTo(0), reason: '$head が無い。変えたならこの検査も直す');
    final end = source.indexOf(';', start);
    expect(end, greaterThan(start), reason: '$head の終端が無い');
    return source.substring(start, end);
  }

  /// `_entitlementSection` の本体を括弧の対応で切り出す。
  ///
  /// ⚠⚠ **引数リストの `{`（名前付き引数）を本体の `{` と取り違えない。**#1217 で
  /// 引数が増えて宣言が複数行になったとき、`indexOf('{')` だと**引数リストを本体
  /// として掴み**、「`watch` が実在する」の前提ごと空振りした（実際に踏んだ）。
  String entitlementSectionBody(String source) {
    final m = RegExp(r'List<Widget> _entitlementSection\(').firstMatch(source);
    expect(m, isNotNull, reason: '_entitlementSection が無い。変えたならこの検査も直す');
    // 引数リストの閉じ括弧まで、丸括弧の対応だけで進める。
    var paren = 1;
    var i = m!.end;
    for (; i < source.length && paren > 0; i++) {
      if (source[i] == '(') paren++;
      if (source[i] == ')') paren--;
    }
    expect(paren, 0, reason: '_entitlementSection の引数リストが閉じていない');
    final open = source.indexOf('{', i);
    expect(open, greaterThan(0));
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i);
      }
    }
    fail('_entitlementSection の終端が見つからない');
  }

  /// 購入結果を待ち受けている `ref.listen` の本体を切り出す。
  ///
  /// ⚠⚠ **ファイル全体で `registerAllAccounts` の不在を見てはいけない。**手押し
  /// のボタン（`_reconcileAfterPurchase`）は**残す**ので、全体で見ると必ず当たる。
  /// **二重登録になるのは listener の中から打った場合だけ。**
  String purchaseListenerBody(String source) {
    const head = 'ref.listen<SupporterPurchaseState>';
    final start = source.indexOf(head);
    expect(start, greaterThanOrEqualTo(0), reason: '$head が無い。変えたならこの検査も直す');
    var paren = 0;
    for (var i = source.indexOf('(', start); i < source.length; i++) {
      if (source[i] == '(') paren++;
      if (source[i] == ')') {
        paren--;
        if (paren == 0) return source.substring(start, i);
      }
    }
    fail('$head の終端が見つからない');
  }

  // ---- 判定ロジック（合成ソースを食わせられる形に切り出す） ----

  /// 利用権 provider の `watch` が、プリセット判定より後ろにあるか。
  ///
  /// ⚠⚠ **順序が本体。**`ref.watch` に到達した時点で provider が起動し、
  /// **商品の問い合わせとキーホルダの読み出しが走る**ので、「表示しない」だけでは
  /// 足りない。
  bool watchGatedByPreset(String expr) {
    // ⚠ 門の綴りは 2 通り認める: `!hasPreset &&`（短絡）と `hasPreset ?`（三項）。
    // **どちらも `ref.watch` へ到達させない**ので目的は同じ。
    //
    // ⚠⚠ **改行をまたぐので固定文字列で探さない。**`dart format` が
    // `hasPreset\n    ? EntitlementView.absent` と割るため、`'hasPreset ?'` では
    // **当たらない**（2026-10-04 に実際に空振りした）。
    final gates = [
      RegExp(r'!\s*hasPreset\s*&&').firstMatch(expr)?.start ?? -1,
      RegExp(r'\bhasPreset\s*\?').firstMatch(expr)?.start ?? -1,
    ].where((i) => i >= 0);
    final watch = expr.indexOf('ref.watch(entitlementStatusProvider)');
    if (gates.isEmpty || watch < 0) return false;
    return gates.reduce((a, b) => a < b ? a : b) < watch;
  }

  /// 画面が `eligible` を自前で組み立てていないか (#1218)。
  ///
  /// ⚠⚠ **これが再発の形。**サービス側に経路が増えても、この綴りが残っていると
  /// 画面だけ古い判定で動き続ける（買った人に「登録対象外」と出す）。
  bool handRollsEligible(String source) =>
      source.contains('hasPreset || PushRegistrationService.isPresetServer(');

  /// `_entitlementSection` が `watch` の前に早期 return で抜けているか。
  bool sectionReturnsBeforeWatch(String body) {
    final gate = body.indexOf('if (hasPreset) return const [];');
    final watch = body.indexOf('ref.watch(');
    if (gate < 0 || watch < 0) return false;
    return gate < watch;
  }

  /// 指定ファイルでの `RelayEntitlementPurchaseSection` の引数の組み合わせ。
  List<String> sectionUsages(String source) => [
    for (final m in RegExp(
      r'RelayEntitlementPurchaseSection\(\s*(?://[^\n]*\n\s*)*'
      r'showBenefit:\s*(true|false)',
    ).allMatches(source))
      m.group(1)!,
  ];

  /// `showLegalNotice:` に渡している値（出現順）。
  List<String> legalNoticeArgs(String source) => [
    for (final m in RegExp(
      r'showLegalNotice:\s*(true|false)',
    ).allMatches(source))
      m.group(1)!,
  ];

  // ---- 1. 判定そのもの（ソース検査ではない純粋な関数） ----

  group('showRelayPurchaseButton', () {
    // ⚠⚠ **`hasPreset` は材料から外れた (#1224)。**節そのものを出すかの門は
    // 呼び出し側（画面）へ移したので、ここは「買える状態か」だけを見る。
    // ⚠ プリセット利用者に節が出ないことは、下の「配線」の
    // `watchGatedByPreset` / `sectionReturnsBeforeWatch` が見ている。
    test('未購入と失効では出す（買えば直る）', () {
      expect(showRelayPurchaseButton(view: EntitlementView.absent), isTrue);
      // ⚠⚠ **失効で出すのが #1219 の修正点。**以前は手元のトークンの有無
      // （`state.hasEntitlement`）でボタンを切り替えていたので、🔴 **失効しても
      // トークンは残るため「取り直す」しか出ず、買い直せなかった。**
      expect(showRelayPurchaseButton(view: EntitlementView.expired), isTrue);
    });

    // ⚠⚠ **ここが二重購入の防止。**持っている人に押せるボタンを出さない。
    test('有効・猶予・返金済みでは出さない', () {
      expect(showRelayPurchaseButton(view: EntitlementView.active), isFalse);
      // ⚠ 猶予は購読が生きている。直し方は支払い方法の更新で、買い直しではない。
      expect(showRelayPurchaseButton(view: EntitlementView.grace), isFalse);
      // ⚠ 返金済みは決済済みの期間が残っていて、まだ届いている（relay#63）。
      expect(showRelayPurchaseButton(view: EntitlementView.refunded), isFalse);
    });

    test('⚠ 状態が増えたら既定は「出さない」側', () {
      // enum を足したときに absent / expired 以外が勝手に入口を増やさないこと。
      final shown = EntitlementView.values
          .where((v) => showRelayPurchaseButton(view: v))
          .toSet();
      expect(shown, {EntitlementView.absent, EntitlementView.expired});
    });
  });

  group('supporterPurchaseOutcomeMessage', () {
    test('⚠⚠ 投げ銭とサブスクで成功の文面が違う（買ったものを取り違えない）', () {
      final tip = supporterPurchaseOutcomeMessage(
        const SupporterPurchaseOutcome(SupporterPurchaseOutcomeKind.success),
      );
      final sub = supporterPurchaseOutcomeMessage(
        const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.success,
          isSubscription: true,
        ),
      );
      expect(tip, contains('サポーター'));
      expect(sub, contains('利用権'));
      expect(tip, isNot(sub));
    });

    test('⚠ 利用権の発行の失敗は「購入できなかった」と言い切らない', () {
      // ⚠ 以前は失敗の種類が `error` 1 つで、サブスクなら全部この文面だった。
      // ストアで決済が通らなかった回（`error`）と分けたので、見る先は
      // `entitlementError`（リリース前レビュー 2026-10-06）。
      final sub = supporterPurchaseOutcomeMessage(
        const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.entitlementError,
          isSubscription: true,
        ),
      );
      // 購入は成立していて利用権の発行だけ落ちた場合があるため。
      expect(sub, isNot(contains('購入を完了できませんでした')));
      expect(sub, contains('利用権'));
    });

    test('キャンセルは種別を問わず同じ', () {
      expect(
        supporterPurchaseOutcomeMessage(
          const SupporterPurchaseOutcome(SupporterPurchaseOutcomeKind.canceled),
        ),
        supporterPurchaseOutcomeMessage(
          const SupporterPurchaseOutcome(
            SupporterPurchaseOutcomeKind.canceled,
            isSubscription: true,
          ),
        ),
      );
    });
  });

  // ---- 2. 走査が空振りしていない ----

  group('⚠ 走査が空振りしていない', () {
    test('前提: 3 つのファイルが実在して読めている', () {
      for (final path in [pushPath, supporterPath, sectionPath]) {
        expect(File(path).existsSync(), isTrue, reason: path);
        expect(read(path).length, greaterThan(500), reason: path);
      }
    });

    test('前提: 共有ウィジェットは 2 画面から使われている（1 箇所ではない）', () {
      expect(sectionUsages(maskComments(read(pushPath))), hasLength(1));
      expect(sectionUsages(maskComments(read(supporterPath))), hasLength(1));
    });

    test('前提: 切り出した式が式であって、ファイル全体ではない', () {
      final source = maskComments(read(pushPath));
      // ⚠ #1224 で `showPurchase` は消えた（購入ボタンの判定はウィジェット側）。
      // 切り出しの前提は、いまも画面に残る `entitlementView` で見る。
      final expr = localExpr(source, 'entitlementView');

      expect(expr, contains('ref.watch(entitlementStatusProvider)'));
      // ⚠⚠ **括弧の取り違えでファイルを丸ごと掴んでいないこと。**丸ごとだと
      // 「門がある」は常に真になり、検査が何も見ていない状態になる。
      expect(expr.length, lessThan(source.length ~/ 4));
      expect(expr, isNot(contains('Widget build(')));
    });

    test('前提: 購入の listener を切り出せていて、ファイル全体ではない', () {
      final source = maskComments(read(pushPath));
      final listener = purchaseListenerBody(source);

      expect(listener, contains('supporterPurchaseProvider'));
      expect(listener, contains('showSnackBar'));
      // ⚠⚠ 丸ごと掴むと「listener から登録していない」が偽になって**落ち続ける**
      // か、逆の綴りでは**常に通る**。どちらでも検査の意味が失われる。
      expect(listener.length, lessThan(source.length ~/ 4));
      expect(listener, isNot(contains('Widget build(')));
      // ⚠ 手押しのボタンは listener の外にあること（内側だと二重登録の検査が
      // 自明に落ちる）。
      expect(listener, isNot(contains('購入を確認して登録し直す')));
    });

    test('前提: _entitlementSection の本体を切り出せていて、watch が実在する', () {
      final body = entitlementSectionBody(maskComments(read(pushPath)));

      expect(body, contains('ref.watch(entitlementStatusProvider)'));
      expect(body, contains('SectionHeader('));
      expect(body.length, lessThan(read(pushPath).length ~/ 2));
    });
  });

  // ---- 3. 判定に合成ソースを食わせる ----

  group('⚠ 判定に合成ソースを食わせる', () {
    test('門が先にある式は通る', () {
      expect(
        watchGatedByPreset(
          'final showPurchase = !hasPreset && '
          'showRelayPurchaseEntry(hasPreset: hasPreset, '
          'view: ref.watch(entitlementStatusProvider).view)',
        ),
        isTrue,
      );
    });

    test('⚠⚠ watch が門より前にある式は検出する', () {
      expect(
        watchGatedByPreset(
          'final showPurchase = ref.watch(entitlementStatusProvider).view == '
          'EntitlementView.absent && !hasPreset && true',
        ),
        isFalse,
      );
    });

    test('⚠ 門が無い式は検出する', () {
      expect(
        watchGatedByPreset(
          'final showPurchase = '
          'ref.watch(entitlementStatusProvider).view == '
          'EntitlementView.absent',
        ),
        isFalse,
      );
    });

    test('早期 return が watch より後ろなら検出する', () {
      expect(
        sectionReturnsBeforeWatch(
          '{ final status = ref.watch(entitlementStatusProvider); '
          'if (hasPreset) return const []; }',
        ),
        isFalse,
      );
      expect(
        sectionReturnsBeforeWatch(
          '{ if (hasPreset) return const []; '
          'final status = ref.watch(entitlementStatusProvider); }',
        ),
        isTrue,
      );
    });

    test('⚠ コメントの中の綴りは数えない', () {
      // 「`showLegalNotice: true` にしない」という注意書きを、設定だと読まない。
      expect(
        legalNoticeArgs(
          maskComments(
            '// ⚠ showLegalNotice: true にしない\n'
            'const RelayEntitlementPurchaseSection('
            'showBenefit: true, showLegalNotice: false)',
          ),
        ),
        ['false'],
      );
    });
  });

  // ---- 4. 本物のソースに当てる ----

  group('配線（本物のソース）', () {
    test('⚠⚠ 利用権 provider の watch はプリセット判定より後ろ', () {
      final source = maskComments(read(pushPath));

      expect(watchGatedByPreset(localExpr(source, 'entitlementView')), isTrue);
      expect(sectionReturnsBeforeWatch(entitlementSectionBody(source)), isTrue);
      // 共有ウィジェット側（サーバー情報 / プロフィール）も同じ門を持つ。
      expect(
        watchGatedByPreset(
          localExpr(maskComments(read(statusSectionPath)), 'hasEntitlement'),
        ),
        isTrue,
      );
    });

    test('⚠⚠ `eligible` を画面で組み立てていない（サービス側の 1 本を呼ぶ）', () {
      for (final path in [pushPath, statusSectionPath]) {
        final source = maskComments(read(path));
        expect(handRollsEligible(source), isFalse, reason: path);
        expect(
          source,
          contains('PushRegistrationService.shouldAttemptRegistration('),
          reason: path,
        );
        // ⚠ 利用権を材料に渡していること（渡さないと呼んでも同じ穴になる）。
        expect(source, contains('hasEntitlement:'), reason: path);
      }
    });

    test('⚠ 画面冒頭の説明が「プリセットが要る」で終わっていない', () {
      final source = maskComments(read(pushPath));

      // ⚠ #1226 で「プッシュ通知リレー」へ揃えた（裸の「リレー」を出さない）。
      // ⚠⚠ **連結の切れ目をまたぐ綴りで固定しない** —— 2 行目は
      // 「…がある場合に」「利用できます。」で割れているので、`contains` は
      // 片側だけを見る。
      expect(source, contains('プッシュ通知リレーの利用権があるため'));
      expect(source, contains('プッシュ通知リレーの利用権がある場合に'));
    });

    test('⚠⚠ 法定表記はプッシュ通知画面にだけ同梱し、サポーター画面では二重にしない', () {
      expect(legalNoticeArgs(maskComments(read(pushPath))), ['true']);
      expect(legalNoticeArgs(maskComments(read(supporterPath))), ['false']);

      // ⚠ サポーター画面は画面レベルの表記を保つ（投げ銭と共通なので、
      // 節へ寄せるとサブスク商品が取れない回に投げ銭の分ごと消える）。
      expect(
        maskComments(read(supporterPath)),
        contains("title: const Text('特定商取引法に基づく表記')"),
      );
    });

    test('⚠⚠ 利用規約とプライバシーポリシーは、節が両画面に出す', () {
      final section = maskComments(read(sectionPath));
      final terms = section.indexOf("title: const Text('利用規約')");
      final privacy = section.indexOf("title: const Text('プライバシーポリシー')");
      final legalGate = section.indexOf('if (showLegalNotice)');
      final productGate = section.indexOf('if (product != null)');

      expect(section, contains('AppConstants.termsUrl'));
      expect(section, contains('AppConstants.privacyPolicyUrl'));
      // ⚠⚠ **`showLegalNotice` の門より手前**（サポーター画面は false なので、
      // 門の内側へ入れるとあちらで消える）。⚠ 商品の門よりは後ろ（買えない
      // 回には出さない）。
      expect(productGate, greaterThanOrEqualTo(0));
      expect(terms, greaterThan(productGate));
      expect(privacy, greaterThan(terms));
      expect(legalGate, greaterThan(privacy));
      // ⚠ 画面の側で自前に持たない（節の 1 本に保つ）。
      for (final path in [pushPath, supporterPath]) {
        expect(
          maskComments(read(path)),
          isNot(contains('privacyPolicyUrl')),
          reason: path,
        );
      }
    });

    test('便益の説明はサポーター画面だけ（プッシュ通知画面では重ねない）', () {
      expect(sectionUsages(maskComments(read(supporterPath))), ['true']);
      expect(sectionUsages(maskComments(read(pushPath))), ['false']);
    });

    test('⚠⚠ 未購入の文面が「サポート画面」へ送り直していない', () {
      // 入口が同じ節に出るので、辿り直させる案内が残ると誤導になる。
      // ⚠ 文面は #1224 で共有ウィジェットへ移ったので、両方を見る。
      for (final path in [pushPath, sectionPath]) {
        expect(
          maskComments(read(path)),
          isNot(contains('サポート画面')),
          reason: path,
        );
      }
    });

    // ---- #1224: できることを 2 画面で完全に同じにする ----

    test('⚠⚠ 4 つの口はすべて共有ウィジェットにある', () {
      final section = maskComments(read(sectionPath));

      // 状態表示 / 購入 / 復元（登録のやり直しを含む）/ 記録を消す。
      // ⚠ #1234 までは復元が「取り直す」と「登録し直す」に分かれていて 5 つだった。
      expect(section, contains('relayEntitlementStatusCopy('));
      expect(section, contains('showRelayPurchaseButton('));
      expect(section, contains("const Text('購入を復元する')"));
      expect(section, contains("const Text('利用権の記録を消す')"));
    });

    // ---- #1234: 復元と登録のやり直しを 1 つにまとめる ----

    test('⚠⚠ 分かれていた 2 つのボタンが戻ってきていない', () {
      // 🔴 名前から違いが読めなかった（「取り直す」は買い直しに、「購入を確認して」は
      // ストアへの問い合わせに読めて、実際は逆）。
      final section = maskComments(read(sectionPath));

      expect(section, isNot(contains('利用権を取り直す')));
      expect(section, isNot(contains('購入を確認して登録し直す')));
    });

    test('⚠⚠ 「お支払いは発生しません」を添えている', () {
      // 「復元」は買い直しと取り違えられやすい。
      expect(maskComments(read(sectionPath)), contains('お支払いは発生しません'));
    });

    test('⚠⚠ 復元のボタンは、登録のやり直しまで行う 1 本を呼ぶ', () {
      final section = maskComments(read(sectionPath));
      final provider = maskComments(
        read('lib/src/provider/supporter_purchase_provider.dart'),
      );

      expect(section, contains('restoreAndReregister()'));
      expect(provider, contains('Future<bool> restoreAndReregister()'));
      // 🔴 **ウィジェットから登録を打たない。**復元で購入が返った回は既存の経路
      // （`_completeAndReregister`）が登録をやり直すので、ここでも打つと relay へ
      // 2 本飛ぶ（#1217 の退行と同じ形）。実体は provider の 1 本に寄せてある。
      expect(section, isNot(contains('registerAllAccounts')));
    });

    test('⚠⚠ 復元で購入が返った回は、まとめた側から登録を打たない', () {
      final provider = maskComments(
        read('lib/src/provider/supporter_purchase_provider.dart'),
      );
      final start = provider.indexOf('Future<bool> restoreAndReregister()');
      expect(start, greaterThan(0));
      final end = provider.indexOf('Future<void> buy(', start);
      expect(end, greaterThan(start), reason: '本体を切り出せていない');
      final body = provider.substring(start, end);

      // 空振りしていないこと（本体に登録の実体がある）。
      expect(body, contains('registerAllAccounts'));
      // ⚠⚠ **購入イベントが届いていたら、登録より前に抜ける。**
      final guard = body.indexOf('if (_subscriptionEventCount != before)');
      expect(guard, greaterThan(0), reason: '⚠ 二重登録を避ける判定が無い');
      expect(guard, lessThan(body.indexOf('registerAllAccounts')));
      // ⚠ 数えているのは到着（処理の完了ではない）。
      expect(provider, contains('_subscriptionEventCount++;'));
    });

    test('⚠⚠ 購入・復元が成立したら、節が自分で状態を引き直す', () {
      // 🔴 以前はプッシュ通知設定画面にしか無く、サポーター画面では買った直後も
      // 「利用権がありません」と購入ボタンが残っていた（二重購入を誘う）。
      final section = maskComments(read(sectionPath));
      final listen = section.indexOf('ref.listen<SupporterPurchaseState>(');
      expect(listen, greaterThan(0), reason: '⚠ 節が購入結果を聞いていない');
      final tail = section.substring(listen, listen + 600);

      expect(tail, contains('SupporterPurchaseOutcomeKind.success'));
      expect(tail, contains('entitlementStatusProvider.notifier'));
      expect(tail, contains('refreshCoalesced()'));
    });

    test('⚠⚠ どちらの画面も自前では持たない（集約が「使わなくなる」形で崩れない）', () {
      // ⚠⚠ **集約系の再発は「壊れること」ではなく「使わなくなること」として
      // 現れる**（docs/CLAUDE.md・#1083-A）。画面側に綴りが戻ってきたら落とす。
      const owned = [
        '購入を復元する',
        // ⚠ #1234 でまとめる前の 2 つ。画面側へ戻ってきても落とす。
        '利用権を取り直す',
        '購入を確認して登録し直す',
        '利用権の記録を消す',
        'registerAllAccounts',
        // 状態別の文面（以前はプッシュ通知画面が自前で持っていた）。
        'EntitlementView.refunded =>',
      ];
      for (final path in [pushPath, supporterPath]) {
        final source = maskComments(read(path));
        for (final spell in owned) {
          expect(source, isNot(contains(spell)), reason: '$path / $spell');
        }
      }
    });

    test('⚠ 画面に残るのは見出しと門だけ', () {
      final body = entitlementSectionBody(maskComments(read(pushPath)));

      expect(body, contains("SectionHeader('プッシュ通知リレーの利用権')"));
      expect(body, contains('RelayEntitlementPurchaseSection('));
      // ⚠ 状態の組み立てが残っていないこと（移設したので switch は無い）。
      expect(body, isNot(contains('switch (status.view)')));
    });

    // ---- #1219: 固着から抜ける口 ----

    test('⚠⚠ 手元のトークンを捨てる口が配線されている', () {
      final provider = maskComments(
        read('lib/src/provider/supporter_purchase_provider.dart'),
      );

      expect(provider, contains('Future<bool> forgetEntitlement()'));
      expect(provider, contains('EntitlementTokenStore.clear()'));
      // ⚠ 捨てたら `hasEntitlement` も落とす（残すとボタンが消えない）。
      expect(provider, contains('hasEntitlement: false'));
    });

    test('⚠⚠ 記録を消すのは確認してから（自動では捨てない）', () {
      final section = maskComments(read(sectionPath));

      expect(section, contains('showDialog<bool>'));
      // ⚠ 何が消えないかを文面で言うこと（購入そのものは消えない）。
      expect(section, contains('ストアでの自動更新も止まりません'));
      // ⚠⚠ **ウィジェットが自分から `clear` を呼んでいない**（必ず provider 経由
      // で、ダイアログの後ろ）。
      expect(section, isNot(contains('EntitlementTokenStore')));
    });

    test('⚠⚠ 購入成功から再登録を打たない（二重登録の防止）', () {
      // 🔴 2026-10-04 の実機確認で実測した退行。購入の成立時点で
      // `SupporterPurchaseNotifier._completeAndReregister` が
      // `registerAllAccounts` を打っているので、画面からも打つと
      // relay へ `register.created` が 2 本飛ぶ。
      final source = maskComments(read(pushPath));
      final listener = purchaseListenerBody(source);

      expect(listener, isNot(contains('registerAllAccounts')));
      expect(listener, isNot(contains('_reconcileAfterPurchase')));
      // ⚠ 足りないのは利用権の引き直しだけ（これが無いと買っても
      // 「利用権がありません」のまま残る）。
      expect(listener, contains('entitlementStatusProvider.notifier'));
      expect(listener, contains('refreshCoalesced()'));
    });

    test('⚠ 手押しで登録をやり直す口は残っている', () {
      // ⚠ #1224 で共有ウィジェットへ移し、#1234 で復元のボタンにまとめた。
      // **消えていないこと**を見るのがこの検査の目的なので、見る先を付け替える
      // （ボタンは節に、登録の実体は provider にある）。
      final section = maskComments(read(sectionPath));
      final provider = maskComments(
        read('lib/src/provider/supporter_purchase_provider.dart'),
      );

      expect(section, contains('_restore(ref)'));
      expect(section, contains("const Text('購入を復元する')"));
      expect(provider, contains('registerAllAccounts'));
    });
  });

  // ---- 5. 歯があることを、穴を開けて確かめる ----

  group('⚠⚠ 歯があることを、穴を開けて確かめる', () {
    String before(String path) {
      final r = Process.runSync('git', [
        'show',
        '$beforeRev:packages/capsicum/$path',
      ], workingDirectory: '../..');
      expect(r.exitCode, 0, reason: (r.stderr as String));
      return r.stdout as String;
    }

    test('#1217 の前は共有ウィジェットが無く、購入導線はサポーター画面だけだった', () {
      final push = maskComments(before(pushPath));
      final supporter = maskComments(before(supporterPath));

      // 共有ウィジェットそのものが無い ＝ 使用箇所の検査は空になる。
      expect(sectionUsages(push), isEmpty);
      expect(sectionUsages(supporter), isEmpty);
      expect(legalNoticeArgs(push), isEmpty);
      // ⚠ サポーター画面には購入のタイルが**直書き**されていた。
      expect(supporter, contains('.subscribe(product)'));
    });

    test('⚠⚠ 前の文面は「サポート画面から」と送り直していた（いまは落ちる形）', () {
      expect(maskComments(before(pushPath)), contains('サポート画面から'));
    });

    test('⚠⚠ 前は門が無い（`showPurchase` が存在しない）', () {
      expect(before(pushPath), isNot(contains('final showPurchase =')));
      // ⚠ 当時も `_entitlementSection` の早期 return はあった（#1123 で入れた）。
      // **こちらは退行していないことの確認**で、穴ではない。
      expect(
        sectionReturnsBeforeWatch(
          entitlementSectionBody(maskComments(before(pushPath))),
        ),
        isTrue,
      );
    });

    test('⚠ 買った直後の登録は前には無かった', () {
      expect(before(pushPath), isNot(contains('_reconcileAfterPurchase')));
    });

    test('⚠⚠ #1218 の前は 2 画面とも `eligible` を自前で組み立てていた', () {
      // 🔴 これが「買った人に登録対象外と出す」の正体。両方で検出されること。
      for (final path in [pushPath, statusSectionPath]) {
        expect(
          handRollsEligible(maskComments(before(path))),
          isTrue,
          reason: path,
        );
        expect(
          maskComments(before(path)),
          isNot(contains('shouldAttemptRegistration(')),
          reason: path,
        );
      }
    });

    test('⚠ 前の文面は利用権という経路を書いていなかった', () {
      expect(before(pushPath), isNot(contains('リレーの利用権がある')));
      expect(
        before(statusSectionPath),
        contains("'登録対象外（プリセットサーバーのアカウントが未登録）'"),
      );
    });

    // ---- #1224 / #1219 の直前（`2e397a92`）で穴を開ける ----

    /// #1224 / #1219 を入れる直前の develop の tip。
    ///
    /// ⚠⚠ **[beforeRev] と分ける。**あちらは #1217 / #1218 の前（`0fb0bae3`）で、
    /// **この回の非対称はまだ入っていない**。歯を確かめるには「非対称が在った
    /// 最後の状態」が要る。
    const asymmetricRev = '2e397a92';

    String beforeAsymmetric(String path) {
      final r = Process.runSync('git', [
        'show',
        '$asymmetricRev:packages/capsicum/$path',
      ], workingDirectory: '../..');
      expect(r.exitCode, 0, reason: (r.stderr as String));
      return r.stdout as String;
    }

    test('⚠⚠ 前は購入ボタンを手元のトークンで切り替えていた（#1219 の穴）', () {
      final section = maskComments(beforeAsymmetric(sectionPath));

      // 🔴 これが「失効しても買い直せない」の正体。
      expect(section, contains('trailing: state.hasEntitlement'));
      // 当時は view を材料にしていなかった。
      expect(section, isNot(contains('showRelayPurchaseButton(')));
    });

    test('⚠⚠ 前は状態表示と「登録し直す」がプッシュ通知画面だけにあった（#1224 の穴）', () {
      final push = maskComments(beforeAsymmetric(pushPath));
      final supporter = maskComments(beforeAsymmetric(supporterPath));

      // プッシュ通知画面が自前で持っていた ＝ いまの「画面は持たない」検査に当たる。
      expect(push, contains('EntitlementView.refunded =>'));
      expect(push, contains("const Text('購入を確認して登録し直す')"));
      // サポーター画面にはどちらも無かった（＝ できることが少なかった側）。
      expect(supporter, isNot(contains('EntitlementView.refunded =>')));
      expect(supporter, isNot(contains('購入を確認して登録し直す')));
    });

    test('⚠⚠ 前は手元のトークンを捨てる口が無かった（#1219 後半）', () {
      final provider = maskComments(
        beforeAsymmetric('lib/src/provider/supporter_purchase_provider.dart'),
      );

      expect(provider, isNot(contains('forgetEntitlement')));
      // 🔴 `clear()` は実装されていたのに、呼び出しが 1 件も無かった。
      expect(provider, isNot(contains('EntitlementTokenStore.clear()')));
    });

    test('⚠⚠ 前は購入の面に利用規約とプライバシーポリシーが無かった', () {
      final r = Process.runSync('git', [
        'show',
        '6d8ababb:packages/capsicum/$sectionPath',
      ], workingDirectory: '../..');
      expect(r.exitCode, 0, reason: (r.stderr as String));
      final section = maskComments(r.stdout as String);

      expect(section, isNot(contains('AppConstants.termsUrl')));
      expect(section, isNot(contains('privacyPolicyUrl')));
      // ⚠ 特商法の表記は当時からあった（走査が空振りしていないことの確認）。
      expect(section, contains('AppConstants.tokushohoUrl'));
    });
  });
}
