import 'dart:io';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/offline_account.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/entitlement_status_provider.dart';
import 'package:capsicum/src/provider/supporter_purchase_provider.dart';
import 'package:capsicum/src/service/entitlement_token_store.dart';
import 'package:capsicum/src/ui/widget/relay_entitlement_purchase_section.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// v2.0 のリリース前レビュー（5 観点 + Codex・2026-10-06）で出た赤の再発防止。
///
/// | | 何が起きていたか |
/// | --- | --- |
/// | 1 | プリセットのサーバーに届かない日に、併用している人へ購入を促す |
/// | 2 | 起動後にプリセットのアカウントを足しても「ご購入が必要です」が残る |
/// | 3 | 利用権の読み出しが 1 度失敗すると、終了まで「未購入」として扱う |
/// | 4 | 画像レイヤの復元が終わる前に「完了」を押すと、前回のレイヤが消える |
/// | 5 | 下書きの添付の復元が終わる前に自動保存が走ると、添付の控えが消える |
///
/// ⚠⚠ 1〜3 は `docs/product-policy.md` の不変条件（**プリセットサーバーの
/// 利用者に課金しない**・買った人にもう一度買わせない）に触れる。
void main() {
  String read(String path) => File(path).readAsStringSync();

  const preset = 'mstdn.b-shock.org';
  const external = 'example.com';
  AccountKey key(String host) =>
      AccountKey(type: BackendType.mastodon, host: host, username: 'me');

  setUp(EntitlementTokenStore.resetCacheForTesting);

  // ---- 1. 接続できていないプリセットのアカウントも数える ----

  group('🔴 接続できていないプリセットのアカウントも「持っている」に数える', () {
    test('判定: オフライン保持の側にしか無くても true', () {
      expect(
        hasPresetAccountIn(
          accounts: [key(external)],
          offlineAccounts: [key(preset)],
        ),
        isTrue,
        reason: '⚠ プリセットのサーバーが落ちた日に、併用している人へ購入を促す',
      );
    });

    test('対照群: どちらにも無ければ false / 接続できている側にあれば true', () {
      expect(
        hasPresetAccountIn(
          accounts: [key(external)],
          offlineAccounts: [key(external)],
        ),
        isFalse,
      );
      expect(
        hasPresetAccountIn(accounts: [key(preset)], offlineAccounts: const []),
        isTrue,
      );
      expect(
        hasPresetAccountIn(accounts: const [], offlineAccounts: const []),
        isFalse,
      );
    });

    test('⚠⚠ 動作確認用の @test は、プリセットの利用者に数えない', () {
      AccountKey named(String host, String username) => AccountKey(
        type: BackendType.mastodon,
        host: host,
        username: username,
      );

      // これしか入っていない端末は、購入の導線が出る側。
      expect(
        hasPresetAccountIn(
          accounts: [named(preset, 'test')],
          offlineAccounts: const [],
        ),
        isFalse,
      );
      expect(
        hasPresetAccountIn(
          accounts: const [],
          offlineAccounts: [named(preset, 'Test')],
        ),
        isFalse,
        reason: '大文字小文字は区別しない・オフライン保持の側も同じ',
      );
      // ⚠⚠ **ほかのプリセットのアカウントが 1 つでもあれば、従来どおり。**
      expect(
        hasPresetAccountIn(
          accounts: [named(preset, 'test'), key(preset)],
          offlineAccounts: const [],
        ),
        isTrue,
      );
      // ⚠ 前方一致で外さない（`tester` や `test2` は普通の利用者）。
      for (final username in ['tester', 'test2', 'mytest']) {
        expect(
          hasPresetAccountIn(
            accounts: [named(preset, username)],
            offlineAccounts: const [],
          ),
          isTrue,
          reason: username,
        );
      }
    });

    test('利用権の状態: プリセットがオフライン保持でも preset になる', () async {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _Accounts(
              AccountManagerState(
                accounts: [_account(external)],
                current: _account(external),
                offlineAccounts: [OfflineAccount(key: key(preset))],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(entitlementStatusProvider);
      await Future<void>.delayed(Duration.zero);

      // 🔴 直す前は preset にならず、購入を促す側へ落ちていた。
      expect(
        container.read(entitlementStatusProvider).view,
        EntitlementView.preset,
      );
    });

    test('⚠⚠ 課金の話を出す側が、接続できたアカウントだけで判定していない（配線）', () {
      // 🔴 以前は 4 箇所とも `hasPresetAmong(accounts)` だった。
      const paths = [
        'lib/src/ui/screen/settings/push_notification_settings_screen.dart',
        'lib/src/ui/widget/push_registration_status_section.dart',
        'lib/src/ui/screen/splash_screen.dart',
        'lib/src/provider/entitlement_status_provider.dart',
      ];
      for (final path in paths) {
        final source = maskComments(read(path));
        expect(
          source,
          contains('hasPresetAccountProvider'),
          reason: '$path が新しい判定を使っていない',
        );
        expect(
          source,
          isNot(contains('hasPresetAmong(')),
          reason: '$path が接続できたアカウントだけで判定している',
        );
      }
    });

    // 2 回目の差分レビュー（2026-10-06）: 上の 4 箇所（画面）は直っていたが、
    // **登録の経路**が接続できたアカウントだけで数えたままだった。プリセットの
    // サーバーに届かない間にトークンが変わると、併用している外部サーバーの
    // 登録を畳んだまま登録し直さず、通知が止まる。
    group('登録の経路も、接続できたアカウントだけで判定していない（配線）', () {
      List<File> libFiles() => sourceFiles('lib');

      /// `registerAllAccounts(` の呼び出しのうち、`hasPreset:` を渡していない
      /// ものの位置。宣言（`static Future<void> registerAllAccounts(`）は除く。
      List<int> callsWithoutHasPreset(String source) {
        final offenders = <int>[];
        for (final m in RegExp(r'registerAllAccounts\(').allMatches(source)) {
          final head = source.substring(
            m.start < 24 ? 0 : m.start - 24,
            m.start,
          );
          if (head.contains('Future<void> ')) continue;
          // 呼び出しの閉じ括弧までを見る（入れ子の括弧を数える）。
          var depth = 0;
          var end = m.end;
          for (var i = m.end - 1; i < source.length; i++) {
            final c = source[i];
            if (c == '(') depth++;
            if (c == ')') depth--;
            if (depth == 0) {
              end = i;
              break;
            }
          }
          if (!source.substring(m.start, end).contains('hasPreset:')) {
            offenders.add(m.start);
          }
        }
        return offenders;
      }

      test('走査が空振りしていない', () {
        final files = libFiles();
        expect(files.length, greaterThan(100));
        final callers = files
            .where(
              (f) => callsWithoutHasPreset(
                maskComments(f.readAsStringSync()).replaceAll('hasPreset:', ''),
              ).isNotEmpty,
            )
            .map((f) => f.path)
            .toList();
        // ⚠ `hasPreset:` を消した版で数えると、呼び出しのあるファイルが出る。
        expect(
          callers,
          containsAll([
            'lib/src/ui/screen/splash_screen.dart',
            'lib/src/provider/supporter_purchase_provider.dart',
            'lib/src/service/push_registration_service.dart',
          ]),
        );
      });

      test('判定が、渡していない呼び出しだけを拾う（合成）', () {
        expect(
          callsWithoutHasPreset('await X.registerAllAccounts(accounts);'),
          hasLength(1),
        );
        expect(
          callsWithoutHasPreset(
            'await X.registerAllAccounts(\n  accounts,\n'
            '  hasPreset: ref.read(p),\n);',
          ),
          isEmpty,
        );
        // 入れ子の括弧の外にある `hasPreset:` には騙されない。
        expect(
          callsWithoutHasPreset(
            'registerAllAccounts(list()); other(hasPreset: true);',
          ),
          hasLength(1),
        );
        // 宣言は数えない。
        expect(
          callsWithoutHasPreset(
            'static Future<void> registerAllAccounts(List<Account> a) async {}',
          ),
          isEmpty,
        );
      });

      test('⚠⚠ lib のどこにも、接続できたアカウントから数える古い判定が無い', () {
        final offenders = <String>[];
        for (final file in libFiles()) {
          final source = maskComments(file.readAsStringSync());
          if (source.contains('hasPresetAmong')) offenders.add(file.path);
          if (callsWithoutHasPreset(source).isNotEmpty) {
            offenders.add('${file.path}（hasPreset を渡していない）');
          }
        }
        expect(offenders, isEmpty);
      });

      test('⚠ アカウントを足した回も、届かないアカウントを数えている', () {
        final source = maskComments(
          read('lib/src/provider/account_manager_provider.dart'),
        );
        // ⚠ #1237 で、登録の相手は [accountsToRegisterAfterAdd] が決める形に
        // なった（プリセットが初めて居るようになった回は全員）。見ているのは
        // 従来どおり「その直前の判定が、届かないアカウントも数えていること」。
        final at = source.indexOf(
          'for (final target in accountsToRegisterAfterAdd(',
        );
        expect(at, greaterThan(0));
        final before = source.substring(at - 900, at);
        expect(before, contains('final hasPreset = hasPresetAccountIn('));
        expect(before, contains('offlineAccounts:'));
        // 判定の結果が、そのまま登録へ渡っている。
        final after = source.substring(at, at + 400);
        expect(
          after,
          contains(
            'PushRegistrationService.registerAccount(target, eligible: hasPreset)',
          ),
        );
      });
    });

    test('⚠ 判定の実体が offlineAccounts を読んでいる（配線）', () {
      final source = maskComments(
        read('lib/src/provider/account_manager_provider.dart'),
      );
      final start = source.indexOf('final hasPresetAccountProvider');
      expect(start, greaterThan(0));
      final body = source.substring(start, start + 400);

      expect(body, contains('state.offlineAccounts'));
      expect(body, contains('state.accounts'));
    });
  });

  // ---- 2. アカウントの増減に追随する ----

  group('🔴 利用権の状態が、アカウントの増減に追随する', () {
    test('起動後にプリセットのアカウントを足すと preset になる', () async {
      late _Accounts accounts;
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => accounts = _Accounts(
              AccountManagerState(
                accounts: [_account(external)],
                current: _account(external),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // ⚠ 画面が見ている状態にする（誰も聞いていないと listen は働かない）。
      final sub = container.listen(entitlementStatusProvider, (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(entitlementStatusProvider).view,
        isNot(EntitlementView.preset),
      );

      accounts.replace(
        AccountManagerState(
          accounts: [_account(external), _account(preset)],
          current: _account(external),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // 🔴 直す前は「ご購入が必要です」のまま残った（再起動するまで）。
      expect(
        container.read(entitlementStatusProvider).view,
        EntitlementView.preset,
      );
    });
  });

  // ---- 2-2. 追い越された読み直しが、先に戻らない（Codex P1・2 巡目）----

  group('🔴 await refresh() のあとで読む状態は、確定している', () {
    // 起動時の未払いの通知（splash の `_notifyUnpaidEntitlement`）と同じ呼び方。
    // notifier を初めて読むと build() が読み直しを予約し、呼び出し元がすぐ
    // もう 1 本を始める ＝ **必ず重なる**。🔴 世代の仕組みを入れた直後は、
    // 明示的に呼んだ側が追い越されて先に戻り、初期値を読んでいた。
    test('provider を初めて読んで、すぐ読み直しを待つ', () async {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _Accounts(
              AccountManagerState(
                accounts: [_account(external)],
                current: _account(external),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(entitlementStatusProvider.notifier).refresh();
      final status = container.read(entitlementStatusProvider);

      expect(status.isRefreshing, isFalse, reason: '⚠ まだ読み直しの途中で戻ってきた');
      // ⚠ テスト環境では保存を読めないので unknown に落ち着く（初期値は absent）。
      expect(status.view, EntitlementView.unknown);
    });

    test('続けて 2 本始めても、先の 1 本は後の 1 本が終わるまで戻らない', () async {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _Accounts(
              AccountManagerState(
                accounts: [_account(external)],
                current: _account(external),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(entitlementStatusProvider.notifier);

      // ⚠ 3 本が重なる（build() が予約した 1 本 + ここで始める 2 本）。
      // **どれを待っても、いちばん新しい 1 本が終わるまで戻らない。**
      // ⚠⚠ 「2 本目が終わったか」では見ない —— 1 本目が待つ相手は 2 本目では
      // なく、その時点でいちばん新しい 1 本（build() が予約したぶん）になる。
      final first = notifier.refresh();
      final second = notifier.refresh();

      await first;
      final afterFirst = container.read(entitlementStatusProvider);
      expect(afterFirst.isRefreshing, isFalse, reason: '⚠ 追い越された側が先に戻った');
      expect(afterFirst.view, EntitlementView.unknown);

      await second;
      expect(
        container.read(entitlementStatusProvider).view,
        EntitlementView.unknown,
      );
    });

    // 2 回目の差分レビュー（並行性・2026-10-06）: 読み直しの中で
    // `hasPresetAccountProvider` を読むと、値が変わっていればその場で listener が
    // 走り、**入れ子の読み直しが始まる**。外側がそのあと「いちばん新しい 1 本」を
    // 自分で上書きしていたので、**自分自身を待って永久に終わらなかった**。
    test('⚠⚠ 読み直しの中で入れ子の読み直しが始まっても、待ちが終わる', () async {
      late _Accounts accounts;
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => accounts = _Accounts(
              AccountManagerState(
                accounts: [_account(external)],
                current: _account(external),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(entitlementStatusProvider.notifier);
      await notifier.refresh();

      // プリセットのアカウントを足す（判定が変わる）→ **同じ同期区間で**読み直す。
      accounts.replace(
        AccountManagerState(
          accounts: [_account(external), _account(preset)],
          current: _account(external),
        ),
      );
      await notifier.refresh().timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('読み直しの待ちが終わらない（自分自身を待っている）'),
      );
      expect(
        container.read(entitlementStatusProvider).view,
        EntitlementView.preset,
      );
    });

    // 同じレビュー: 「記録を消す」は読み直しの世代を進めていなかったので、
    // 応答待ちの読み直しが、消している最中に着いた応答を**保存し直せた**。
    test('⚠⚠ 進行中の読み直しを無効にしても、その待ちは終わる', () async {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _Accounts(
              AccountManagerState(
                accounts: [_account(external)],
                current: _account(external),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(entitlementStatusProvider.notifier);
      // ⚠ build() が予約した 1 本を先に終わらせる（残すと、それが「後続」になって
      // 待ちが終わってしまい、欠陥が見えない）。
      await notifier.refresh();

      final running = notifier.refresh();
      notifier.invalidatePending();
      // ⚠ 無効にしただけで後続を始めていない。待つ相手がいないので、すぐ終わる。
      await running.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('無効にされた読み直しが、自分自身を待っている'),
      );
    });

    test('⚠⚠ 記録を消す・保存する前に、進行中の読み直しを無効にする（配線）', () {
      final source = maskComments(
        read('lib/src/provider/supporter_purchase_provider.dart'),
      );
      for (final write in [
        'await EntitlementTokenStore.clear()',
        'await EntitlementTokenStore.save(token)',
      ]) {
        final at = source.indexOf(write);
        expect(at, greaterThan(0), reason: '$write が見つからない');
        final before = source.substring(at - 300, at);
        expect(
          before,
          contains('invalidatePending()'),
          reason: '$write の前に無効化していない',
        );
      }
    });
  });

  // ---- 3. 読めなかったことを「持っていない」にしない ----

  group('🔴 利用権を読めなかったことを「未購入」にしない', () {
    test('読めなければ unknown（absent ではない）', () async {
      // ⚠ テスト環境には secure storage のプラグインが無いので、読み出しは
      // 必ず失敗する ＝ **「読めない回」そのもの**。
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _Accounts(
              AccountManagerState(
                accounts: [_account(external)],
                current: _account(external),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(entitlementStatusProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // 🔴 直す前は absent（「利用権がありません」と購入ボタン）だった。
      expect(
        container.read(entitlementStatusProvider).view,
        EntitlementView.unknown,
      );
    });

    test('⚠⚠ unknown では購入ボタンを出さず、復元の口は出す', () {
      expect(showRelayPurchaseButton(view: EntitlementView.unknown), isFalse);
      expect(
        showRelayEntitlementActions(view: EntitlementView.unknown),
        isTrue,
      );
    });

    test('⚠⚠ unknown の文面が「無い」と告げたり、購入を勧めたりしない', () {
      final (title, body, _) = relayEntitlementStatusCopy(
        view: EntitlementView.unknown,
        expiresAt: null,
      );
      final text = '$title$body';
      for (final forbidden in ['ありません', '購入', '失効', '月額']) {
        expect(text.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    // 2 回目の差分レビュー（2026-10-06）。
    test('⚠ unknown の文面が、効かない操作を指していない', () {
      final (_, body, _) = relayEntitlementStatusCopy(
        view: EntitlementView.unknown,
        expiresAt: null,
      );
      // 画面を開き直しても読み直さない（読み直すのは起動時と、購入・復元のあと）。
      expect(body, isNot(contains('この画面を開いて')));
      expect(body, contains('アプリを開き直す'));
    });

    test('⚠ 設定画面は、unknown のときに「利用権があるため」と言い切らない（配線）', () {
      final source = maskComments(
        read(
          'lib/src/ui/screen/settings/push_notification_settings_screen.dart',
        ),
      );
      final at = source.indexOf('switch ((');
      expect(at, greaterThan(0));
      final head = source.substring(at, at + 200);
      expect(head, contains('entitlementView != EntitlementView.unknown'));
      // ⚠ 登録を試みる側の判定は変えていない（分からない回も試みる）。
      // ⚠ #1237 で 2 画面の写しを [attemptsRegistrationWith] へ寄せたので、
      // 配線と、判定そのものの両方を見る。
      expect(
        source,
        contains(
          'final hasEntitlement = attemptsRegistrationWith(entitlementView);',
        ),
      );
      expect(attemptsRegistrationWith(EntitlementView.unknown), isTrue);
      expect(attemptsRegistrationWith(EntitlementView.expired), isTrue);
      expect(attemptsRegistrationWith(EntitlementView.active), isTrue);
      expect(attemptsRegistrationWith(EntitlementView.absent), isFalse);
    });

    test('読めなければ load は null、loadOrThrow は例外（区別できる）', () async {
      expect(await EntitlementTokenStore.load(), isNull);
      await expectLater(EntitlementTokenStore.loadOrThrow(), throwsA(anything));
    });

    test('⚠⚠ 読めなかった結果を確定させない（配線）', () {
      final source = maskComments(
        read('lib/src/service/entitlement_token_store.dart'),
      );
      final start = source.indexOf('static Future<EntitlementToken?> load()');
      final end = source.indexOf(
        'static Future<EntitlementToken?> loadOrThrow()',
      );
      expect(start, greaterThan(0));
      expect(end, greaterThan(start), reason: '本体を切り出せていない');
      final load = source.substring(start, end);

      // 🔴 以前は catch のあとで `_loaded = true` にしていた。
      expect(load, isNot(contains('_loaded = true')));
      expect(load, isNot(contains('_cached = null')));
      expect(load, contains('loadOrThrow()'));
    });

    test('⚠⚠ 購入の画面は loadOrThrow を使う（null を未購入と読まない）', () {
      for (final path in [
        'lib/src/provider/entitlement_status_provider.dart',
        'lib/src/provider/supporter_purchase_provider.dart',
      ]) {
        final source = maskComments(read(path));
        expect(source, contains('EntitlementTokenStore.loadOrThrow()'));
        expect(
          source,
          isNot(contains('EntitlementTokenStore.load()')),
          reason: '$path が、読めない回を「持っていない」と読む',
        );
      }
    });
  });

  // ---- 文面: 「プリセット以外のサーバーでは」と、もう無い操作名 ----

  group('利用権の状態の文面', () {
    test('⚠⚠ どの状態も「プリセット以外」と言わない', () {
      // この文面を読むのは全員「プリセットを持たない人」（持つ人は preset へ行く）。
      for (final view in EntitlementView.values) {
        if (view == EntitlementView.preset) continue;
        for (final expiresAt in [null, '2026-11-03 12:34:56']) {
          final (title, body, _) = relayEntitlementStatusCopy(
            view: view,
            expiresAt: expiresAt,
          );
          expect('$title$body', isNot(contains('プリセット以外')), reason: '$view');
        }
      }
    });

    test('⚠ もう無い操作名を指していない（#1234 でボタンは 1 つになった）', () {
      for (final view in EntitlementView.values) {
        final (_, body, _) = relayEntitlementStatusCopy(
          view: view,
          expiresAt: null,
        );
        expect(body, isNot(contains('登録をやり直す')), reason: '$view');
        expect(body, isNot(contains('取り直')), reason: '$view');
      }
      // 猶予は、実在するボタンの名前で直し方を案内する。
      final (_, grace, _) = relayEntitlementStatusCopy(
        view: EntitlementView.grace,
        expiresAt: null,
      );
      expect(grace, contains('購入を復元する'));
    });
  });

  // ---- 購入・復元の結果の文面 ----

  group('購入・復元の結果', () {
    String message(SupporterPurchaseOutcomeKind kind, {bool sub = true}) =>
        supporterPurchaseOutcomeMessage(
          SupporterPurchaseOutcome(kind, isSubscription: sub),
        );

    test('⚠⚠ 復元できる購入が無かった回に、何か出す', () {
      final text = message(SupporterPurchaseOutcomeKind.nothingToRestore);
      expect(text, isNotEmpty);
      expect(text, contains('見つかりません'));
    });

    test('⚠ 3 種類の失敗を別の文面で言う', () {
      final store = message(SupporterPurchaseOutcomeKind.error);
      final entitlement = message(
        SupporterPurchaseOutcomeKind.entitlementError,
      );
      final restore = message(SupporterPurchaseOutcomeKind.restoreError);

      expect({store, entitlement, restore}, hasLength(3));
      // ⚠⚠ 購入は成立していて利用権の発行だけ落ちた回に、「購入できなかった」と
      // 言わない。
      expect(entitlement, isNot(contains('購入を完了できませんでした')));
      expect(restore, contains('復元'));
    });

    test('⚠⚠ ストアのエラーに「サブスクの購入か」を載せている（配線）', () {
      // 🔴 以前は常に false で、プッシュ通知設定画面（サブスクの結果だけを
      // 出す）ではストアのエラーが表示されなかった。
      final source = maskComments(
        read('lib/src/provider/supporter_purchase_provider.dart'),
      );
      final start = source.indexOf('case SupporterPurchaseEventStatus.error:');
      final end = source.indexOf(
        'case SupporterPurchaseEventStatus.purchased:',
      );
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));

      expect(
        source.substring(start, end),
        contains(
          'isSubscription: event.productId == supporterSubscriptionProductId',
        ),
      );
    });

    test('⚠⚠ 復元が空振りした回に nothingToRestore を立てる（配線）', () {
      final source = maskComments(
        read('lib/src/provider/supporter_purchase_provider.dart'),
      );
      final start = source.indexOf('Future<bool> restoreAndReregister()');
      final end = source.indexOf('Future<void> buy(', start);
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      // ⚠ #1237 で、何を立てるかの判定は [outcomeAfterRestoreFallback] へ
      // 切り出した（遅れて届いた購入があれば「無かった」と言わない）。配線と、
      // 判定そのものの両方を見る。
      expect(body, contains('outcomeAfterRestoreFallback('));
      expect(body, contains('state.lastOutcome,'));
      expect(
        outcomeAfterRestoreFallback(null, arrivedLate: false)?.kind,
        SupporterPurchaseOutcomeKind.nothingToRestore,
      );
      // ⚠ 復元そのものの失敗（restoreError）を上書きしない。
      const failed = SupporterPurchaseOutcome(
        SupporterPurchaseOutcomeKind.restoreError,
        isSubscription: true,
      );
      expect(outcomeAfterRestoreFallback(failed, arrivedLate: false), failed);
    });
  });

  // ---- 4. 画像レイヤ: 復元が終わるまで編集画面を出さない ----

  group('🔴 画像レイヤの復元が終わるまで、編集画面を出さない', () {
    test('元画像を出すのは、レイヤを戻し終えたあと（順序）', () {
      final source = maskComments(
        read('lib/src/ui/screen/image_overlay_screen.dart'),
      );
      final start = source.indexOf('Future<void> _decode() async');
      final end = source.indexOf('Future<void> _restoreLayers() async');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start), reason: '本体を切り出せていない');
      final body = source.substring(start, end);

      final restore = body.indexOf('await _restoreLayers();');
      final expose = body.indexOf('_image = ');
      expect(restore, greaterThan(0));
      expect(expose, greaterThan(0));
      // 🔴 以前は逆順で、復元の途中に「完了」を押せた。
      expect(restore, lessThan(expose), reason: '⚠ 復元の途中で「完了」を押すと、前回のレイヤが消える');
      // ⚠ `_image` を出す箇所は 1 つだけ（先に出す経路が別に無い）。
      expect('_image = '.allMatches(body), hasLength(1));
    });

    test('前提: 「完了」と本文は `_image` が出るまで出ない', () {
      final source = maskComments(
        read('lib/src/ui/screen/image_overlay_screen.dart'),
      );
      expect(source, contains('else if (image != null)'));
      expect(source, contains("child: const Text('完了')"));
      expect(source, contains('body: image == null || size == null'));
    });
  });

  // ---- 5. 下書き: 添付を戻し終えるまで自動保存を解禁しない ----

  group('🔴 下書きの添付を戻し終えるまで、自動保存を解禁しない', () {
    test('保存済みがある経路では、添付の復元より前に解禁しない（順序）', () {
      final source = maskComments(
        read('lib/src/ui/screen/compose_screen.dart'),
      );
      final start = source.indexOf('Future<void> _restoreDraft() async');
      final end = source.indexOf('Future<void> _clearDraft(');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start), reason: '本体を切り出せていない');
      final body = source.substring(start, end);

      // 保存済みが無い回の早期 return（ここでは解禁してよい）。
      final gate = body.indexOf('if (!mounted || saved == null) {');
      expect(gate, greaterThan(0));
      final afterGate = body.indexOf('}', gate);
      final resolve = body.indexOf('resolveComposeDraftAttachments(');
      expect(resolve, greaterThan(afterGate));

      // 🔴 以前はこの区間に `_draftRestored = true` があった ＝ 添付が空の
      // まま保存が走れた。
      expect(
        body.substring(afterGate, resolve),
        isNot(contains('_draftRestored = true')),
        reason: '⚠ 添付を戻す前に自動保存が走ると、下書きの添付の控えが消える',
      );
      // ⚠ 戻し終えたあとでは必ず解禁する（false のままだと保存が永久に止まる）。
      final addAll = body.indexOf('_attachments.addAll(');
      expect(addAll, greaterThan(resolve));
      expect(body.substring(addAll), contains('_draftRestored = true'));
    });

    // 🔴 Codex P1・2 巡目。1 巡目の修正は、添付の復元が例外で落ちた回に
    // 「解禁して投げ直す」形で、次の自動保存が空の添付で上書きしていた。
    test('添付を戻せなかった回は、控えを持ち越して保存に載せる（配線）', () {
      final source = maskComments(
        read('lib/src/ui/screen/compose_screen.dart'),
      );
      final start = source.indexOf('Future<void> _restoreDraft() async');
      final end = source.indexOf('Future<void> _clearDraft(');
      final restore = source.substring(start, end);
      final tryAt = restore.indexOf('resolveComposeDraftAttachments(');
      final catchAt = restore.indexOf('} catch (e, st) {', tryAt);
      expect(catchAt, greaterThan(tryAt), reason: '失敗時の分岐を切り出せていない');
      final failure = restore.substring(
        catchAt,
        restore.indexOf(
          'if (!mounted || epoch != _draftClearEpoch) {',
          catchAt,
        ),
      );

      // 控えを持ち越す。
      expect(
        failure,
        contains('_unrestoredDraftAttachments = saved.attachments'),
      );
      // ⚠ 投げ直さない（呼び出し側は fire-and-forget）。
      expect(failure, isNot(contains('rethrow')));
      // ⚠ 保存は解禁する（false のままだと本文が保存されなくなる）。
      expect(failure, contains('_draftRestored = true'));

      // 🔴 自動保存が、その控えを載せ直している。
      final saveStart = source.indexOf('Future<void> _saveDraft() async');
      final save = source.substring(saveStart, start);
      expect(save, contains('..._unrestoredDraftAttachments'));
      expect(
        save,
        contains('_attachments.length + _unrestoredDraftAttachments.length'),
      );

      // ⚠ 下書きを消したら、控えも捨てる（消したはずの添付を書き戻さない）。
      final clear = source.substring(end, end + 400);
      expect(clear, contains('_unrestoredDraftAttachments = const []'));
    });

    // 🔴 Codex P1・3 巡目。本文は添付より先に戻るので、その間に投稿すると
    // 本文だけが出て、直後の消去が添付の控えを消す。
    test('下書きを戻している最中と、戻せなかった回は、そのまま投稿しない（配線）', () {
      final source = maskComments(
        read('lib/src/ui/screen/compose_screen.dart'),
      );
      final start = source.indexOf('Future<void> _submitInternal() async');
      expect(start, greaterThan(0));
      // 投稿前確認（既存）より前の区間だけを見る。
      final end = source.indexOf('confirmBeforePostProvider', start);
      expect(end, greaterThan(start), reason: '本体を切り出せていない');
      final head = source.substring(start, end);

      expect(head, contains('if (_draftAutoSave && !_draftRestored) {'));
      // ⚠⚠ **`_draftAutoSave` 抜きで止めない。**下書きの復元は新規の投稿画面
      // でしか走らないので、無条件に止めると**返信・引用・テンプレートで
      // 永久に投稿できなくなる**。
      expect(
        RegExp(r'if \(!_draftRestored\)').hasMatch(head),
        isFalse,
        reason: '⚠ 返信・引用の画面で投稿できなくなる',
      );
      // 戻せなかった添付がある回は、確かめる。
      expect(head, contains('if (_unrestoredDraftAttachments.isNotEmpty) {'));
      expect(head, contains('showDialog<bool>'));
      expect(head, contains('if (proceed != true) return;'));
    });

    // 2 回目の差分レビュー（並行性・2026-10-06）: 本文を戻した時点で「取消」の
    // バナーが出ているので、添付の実在確認が終わる前に取消せる。そのまま
    // 続けると、取消した下書きの添付（失敗した回は見えない控え）が生き返る。
    test('⚠⚠ 添付を待つ間に下書きを消されたら、添付も控えも入れない（配線）', () {
      final source = maskComments(
        read('lib/src/ui/screen/compose_screen.dart'),
      );
      final start = source.indexOf('Future<void> _restoreDraft() async');
      final end = source.indexOf('Future<void> _clearDraft(');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start), reason: '本体を切り出せていない');
      final body = source.substring(start, end);

      final snapshot = body.indexOf('final epoch = _draftClearEpoch;');
      final resolve = body.indexOf('resolveComposeDraftAttachments(');
      final carry = body.indexOf(
        '_unrestoredDraftAttachments = saved.attachments',
      );
      final add = body.indexOf('_attachments.addAll(');
      expect(snapshot, greaterThan(0));
      expect(snapshot, lessThan(resolve), reason: '待つ前に控えていない');
      expect(carry, greaterThan(resolve));
      expect(add, greaterThan(carry));

      // 控えを持ち越す前と、添付を入れる前の両方で、消されていないかを見る。
      const check = 'epoch != _draftClearEpoch';
      expect(
        body.substring(resolve, carry),
        contains(check),
        reason: '⚠ 失敗した回に、取消した下書きの控えを持ち越す',
      );
      expect(
        body.substring(carry, add),
        contains(check),
        reason: '⚠ 成功した回に、取消した下書きの添付を入れる',
      );

      // 消す側が数を進めている。
      final clear = source.substring(end, end + 200);
      expect(clear, contains('_draftClearEpoch++'));
    });

    test('前提: 下書きの復元と自動保存は、新規の投稿画面でだけ有効になる', () {
      final source = maskComments(
        read('lib/src/ui/screen/compose_screen.dart'),
      );
      // ⚠ 有効にする箇所が増えたら、上の門の条件も見直す。
      expect('_draftAutoSave = true'.allMatches(source), hasLength(1));
      final at = source.indexOf('_draftAutoSave = true');
      expect(source.substring(at, at + 80), contains('_restoreDraft();'));
    });

    test('前提: 自動保存は `_draftRestored` を門にしている', () {
      final source = maskComments(
        read('lib/src/ui/screen/compose_screen.dart'),
      );
      expect(
        source,
        contains('if (!_draftAutoSave || !_draftRestored) return;'),
      );
    });
  });
}

/// 状態を差し替えられるアカウント管理。
class _Accounts extends AccountManagerNotifier {
  _Accounts(this._initial);

  final AccountManagerState _initial;

  @override
  AccountManagerState build() => _initial;

  void replace(AccountManagerState next) => state = next;
}

class _Adapter extends Mock implements DecentralizedBackendAdapter {}

Account _account(String host) => Account(
  key: AccountKey(type: BackendType.mastodon, host: host, username: 'me'),
  adapter: _Adapter(),
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);
