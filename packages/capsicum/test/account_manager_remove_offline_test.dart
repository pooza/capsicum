import 'dart:io';

import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/offline_account.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/compose_draft_store.dart';
import 'package:capsicum/src/service/timeline_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1014: `removeOfflineAccount` を [AccountManagerNotifier.logout] と同じ
/// 後始末に揃える。
///
/// ⚠ **この経路は「未接続アカウントにとっての logout」そのもの。** 到達不能に
/// なったアカウント (#792) と、#967 で「未接続」として並ぶ取り込みアカウントは、
/// ユーザーから見れば削除の意味が logout と変わらない。にもかかわらず #964 の
/// 下書き掃除は `logout` にしか足されておらず、**削除したあとで同じ
/// `@user@host` へ入り直すと、消したはずのアカウントの下書きが復活していた**
/// （Codex P2 / リリース PR #1003）。
///
/// 掃除そのものの正しさ（巻き添えで他アカウントを消さない等）は
/// `compose_draft_store_test.dart` の「アカウント別スロット」群が持つ。ここが
/// 見るのは **削除経路がそれを呼ぶかどうか**だけ。
class _FakeAccountStorage extends AccountStorage {
  final removed = <String>[];

  @override
  Future<void> removeAccount(String accountKey) async {
    removed.add(accountKey);
  }
}

void main() {
  const alice = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );
  const bob = AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example',
    username: 'bob',
  );

  final fixedNow = DateTime.utc(2026, 8, 23, 12);

  late _FakeAccountStorage storage;
  late Directory cacheDir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = _FakeAccountStorage();
    // `removeOfflineAccount` は TL キャッシュ (#890) も消す。実体を与えないと
    // path_provider が無くて内部の catch に落ち、テスト出力が例外ログで埋まる
    // （掃除自体は成功扱いになるので、素通しでも結果は変わらない）。
    cacheDir = Directory.systemTemp.createTempSync('capsicum_tl_cache');
    TimelineCache.directoryOverride = cacheDir.path;
  });

  tearDown(() {
    TimelineCache.directoryOverride = null;
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  ProviderContainer containerWith(AccountManagerState state) {
    final container = ProviderContainer(
      overrides: [accountStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    // build() を走らせてから差し替える（Notifier は state の初期化が要る）。
    container.read(accountManagerProvider);
    container.read(accountManagerProvider.notifier).state = state;
    return container;
  }

  test('削除したアカウントの下書きは残らない', () async {
    await ComposeDraftStore(
      accountKey: alice.toStorageKey(),
    ).save(const ComposeDraft(text: 'alice の書きかけ'), now: fixedNow);

    final container = containerWith(
      const AccountManagerState(
        offlineAccounts: [OfflineAccount.secretMissing(key: alice)],
      ),
    );

    await container
        .read(accountManagerProvider.notifier)
        .removeOfflineAccount(alice);

    expect(
      await ComposeDraftStore(accountKey: alice.toStorageKey()).restore(),
      isNull,
      reason: '残すと、同じ @user@host で入り直したときに復活する',
    );
    expect(storage.removed, [alice.toStorageKey()]);
    expect(
      container.read(accountManagerProvider).offlineAccounts,
      isEmpty,
      reason: '一覧からも消える（従来どおり）',
    );
  });

  // 掃除はアカウント単位。削除していない相手の書きかけを巻き添えにすると、
  // 「別のアカウントを消したら自分の下書きが消えた」になる。
  test('残したアカウントの下書きは巻き添えにしない', () async {
    await ComposeDraftStore(
      accountKey: alice.toStorageKey(),
    ).save(const ComposeDraft(text: 'alice の書きかけ'), now: fixedNow);
    await ComposeDraftStore(
      accountKey: bob.toStorageKey(),
    ).save(const ComposeDraft(text: 'bob の書きかけ'), now: fixedNow);

    final container = containerWith(
      const AccountManagerState(
        offlineAccounts: [
          OfflineAccount.secretMissing(key: alice),
          OfflineAccount(key: bob),
        ],
      ),
    );

    await container
        .read(accountManagerProvider.notifier)
        .removeOfflineAccount(alice);

    expect(
      (await ComposeDraftStore(accountKey: bob.toStorageKey()).restore())!.text,
      'bob の書きかけ',
    );
    expect(
      container.read(accountManagerProvider).offlineAccounts.single.key,
      bob,
    );
  });

  // 到達不能 (#792) と未接続 (#967) で扱いを変えない。どちらもユーザーが
  // 明示的に消した相手なので、下書きを残す理由が無い。
  test('到達不能で保持していたアカウントでも同じ', () async {
    await ComposeDraftStore(
      accountKey: bob.toStorageKey(),
    ).save(const ComposeDraft(text: 'bob の書きかけ'), now: fixedNow);

    final container = containerWith(
      const AccountManagerState(
        offlineAccounts: [OfflineAccount(key: bob, retrying: true)],
      ),
    );

    await container
        .read(accountManagerProvider.notifier)
        .removeOfflineAccount(bob);

    expect(
      await ComposeDraftStore(accountKey: bob.toStorageKey()).restore(),
      isNull,
    );
  });
}
