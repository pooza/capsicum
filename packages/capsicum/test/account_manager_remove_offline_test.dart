import 'dart:io';

import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/offline_account.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/compose_draft_store.dart';
import 'package:capsicum/src/service/notification_label_cache.dart';
import 'package:capsicum/src/service/timeline_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

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
    // [NotificationLabelCache] は SharedPreferencesAsync 側（iOS / macOS では
    // App Group の suite）を使うので、legacy の mock とは別に挿す。
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    // `removeOfflineAccount` は push 鍵も消す (#1024)。実体が無いと
    // MissingPluginException が内部の catch に落ち、テスト出力が例外ログで
    // 埋まる（TL キャッシュに実ディレクトリを与えているのと同じ理由）。
    FlutterSecureStorage.setMockInitialValues({});
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

  // #1024: 真上の doc が「[logout] と同じ後始末を漏らさないこと」と宣言して
  // いるのに、通知ラベルの表示名キャッシュだけ `logout` にしか無かった。
  // ⚠ 消し忘れると、同じ `@user@host` へ入り直したときに**古いラベル**を引く
  // （ラベルは push の payload 整形に使われ、バックグラウンド isolate / NSE /
  // Windows の bg task からも読まれる）。
  test('削除したアカウントの通知ラベルは残らない', () async {
    const labelKey = 'alice@mstdn.example';
    await NotificationLabelCache.save(
      labelKey,
      reblogLabel: 'リキュア！',
      postLabel: 'とうこう',
    );
    // 前提の確認。保存できていないと、このあとの expect は何も見ていない。
    expect(await NotificationLabelCache.readReblog(labelKey), 'リキュア！');

    final container = containerWith(
      const AccountManagerState(
        offlineAccounts: [OfflineAccount.secretMissing(key: alice)],
      ),
    );

    await container
        .read(accountManagerProvider.notifier)
        .removeOfflineAccount(alice);

    expect(
      await NotificationLabelCache.readReblog(labelKey),
      'ブースト',
      reason: '保存が消えて既定値に戻る。残ると入り直したときに古いラベルを引く',
    );
    expect(await NotificationLabelCache.readPost(labelKey), '投稿');
  });

  // ラベルのキーは `username@host`。掃除の巻き添えでよそのアカウントの
  // ラベルを消すと、そちらの通知だけ既定文言に戻る。
  test('残したアカウントの通知ラベルは巻き添えにしない', () async {
    await NotificationLabelCache.save(
      'bob@misskey.example',
      reblogLabel: 'リノート',
      postLabel: 'ノート',
    );

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
      await NotificationLabelCache.readReblog('bob@misskey.example'),
      'リノート',
    );
    expect(await NotificationLabelCache.readPost('bob@misskey.example'), 'ノート');
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
