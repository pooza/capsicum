import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/supporter_status_provider.dart';
import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:capsicum/src/service/supporter_status_store.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #596 サポーター状態のサーバー同期ロジック検証。
/// 採用（他端末で投げ銭済み）・バックフィル（ローカル先行レコードの
/// 汲み上げ）・増分送信・relay 不通時の degrade を対象にする。
class _FakeAdapter extends Mock implements DecentralizedBackendAdapter {}

class _MockUser extends Mock implements User {}

class _MockUserSecret extends Mock implements UserSecret {}

class _TestAccountNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() => const AccountManagerState();

  void setAccounts(List<Account> accounts) {
    state = AccountManagerState(
      accounts: accounts,
      current: accounts.isEmpty ? null : accounts.first,
    );
  }
}

class _MemoryStore implements SupporterStatusStore {
  SupporterRecord record;

  _MemoryStore([this.record = SupporterRecord.empty]);

  @override
  Future<SupporterRecord> load() async => record;

  @override
  Future<void> save(SupporterRecord value) async => record = value;
}

typedef _TipCall = ({
  String account,
  String server,
  String? sku,
  DateTime? tippedAt,
  int count,
});

/// relay 呼び出しを記録する fake。`serverRecords` に入れたアカウントだけ
/// fetch がヒットする。`failing` で全呼び出しを relay 不通相当にする。
class _FakeRelayClient extends PushRelayClient {
  final Map<String, Map<String, dynamic>> serverRecords = {};
  final List<_TipCall> tips = [];
  bool failing = false;

  @override
  Future<Map<String, dynamic>?> fetchSupporterStatus({
    required String account,
    required String server,
  }) async {
    if (failing) throw Exception('relay unreachable');
    return serverRecords[account];
  }

  @override
  Future<Map<String, dynamic>> recordSupporterTip({
    required String account,
    required String server,
    String? sku,
    DateTime? tippedAt,
    int count = 1,
  }) async {
    if (failing) throw Exception('relay unreachable');
    tips.add((
      account: account,
      server: server,
      sku: sku,
      tippedAt: tippedAt,
      count: count,
    ));
    return {'account': account, 'server': server};
  }
}

/// 最初の relay 呼び出し（fetch / tip いずれか）を [release] するまで宙吊りに
/// する fake。連続ログインの race (#701) を決定的に再現するために使う。
class _GatedRelayClient extends _FakeRelayClient {
  final Completer<void> _firstGate = Completer<void>();
  bool _firstCallSeen = false;

  void release() {
    if (!_firstGate.isCompleted) _firstGate.complete();
  }

  Future<void> _gate() async {
    if (!_firstCallSeen) {
      _firstCallSeen = true;
      await _firstGate.future;
    }
  }

  @override
  Future<Map<String, dynamic>?> fetchSupporterStatus({
    required String account,
    required String server,
  }) async {
    await _gate();
    return super.fetchSupporterStatus(account: account, server: server);
  }

  @override
  Future<Map<String, dynamic>> recordSupporterTip({
    required String account,
    required String server,
    String? sku,
    DateTime? tippedAt,
    int count = 1,
  }) async {
    await _gate();
    return super.recordSupporterTip(
      account: account,
      server: server,
      sku: sku,
      tippedAt: tippedAt,
      count: count,
    );
  }
}

Account _makeAccount(String username, String host) => Account(
  key: AccountKey(type: BackendType.mastodon, host: host, username: username),
  adapter: _FakeAdapter(),
  user: _MockUser(),
  userSecret: _MockUserSecret(),
);

Future<void> _settle() async {
  // listener 発火 → 非同期同期 (store load + relay 往復) を流しきる。
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _MemoryStore store;
  late _FakeRelayClient relay;
  late _TestAccountNotifier accounts;
  late ProviderContainer container;

  ProviderContainer createContainer() => ProviderContainer(
    overrides: [
      supporterStatusStoreProvider.overrideWithValue(store),
      supporterRelayClientProvider.overrideWithValue(relay),
      accountManagerProvider.overrideWith(_TestAccountNotifier.new),
    ],
  );

  setUp(() {
    store = _MemoryStore();
    relay = _FakeRelayClient();
  });

  tearDown(() => container.dispose());

  Future<void> start() async {
    container = createContainer();
    accounts =
        container.read(accountManagerProvider.notifier) as _TestAccountNotifier;
    // notifier を起こして build + listener を張る。
    await container.read(supporterStatusProvider.future);
  }

  test('他端末で投げ銭済み: サーバーレコードを採用してバッジが立つ', () async {
    relay.serverRecords['alice@h1'] = {
      'first_tipped_at': '2026-01-01 00:00:00',
      'tip_count': 2,
    };
    await start();
    accounts.setAccounts([_makeAccount('alice', 'h1')]);
    await _settle();

    expect(container.read(isSupporterProvider), isTrue);
    expect(store.record.syncedToServer, isTrue);
    expect(store.record.firstTippedAt!.toUtc(), DateTime.utc(2026, 1, 1));
    expect(relay.tips, isEmpty); // 採用のみで送信はしない
  });

  test('サーバー未登録: 非サポーターのまま', () async {
    await start();
    accounts.setAccounts([_makeAccount('alice', 'h1')]);
    await _settle();

    expect(container.read(isSupporterProvider), isFalse);
    expect(store.record.syncedToServer, isFalse);
  });

  test('ローカル先行レコード: 全アカウントへバックフィルして synced になる', () async {
    final tippedAt = DateTime.utc(2026, 3, 1);
    store = _MemoryStore(
      SupporterRecord(
        firstTippedAt: tippedAt,
        tipCount: 3,
        lastSku: 'supporter.tip.small',
      ),
    );
    relay = _FakeRelayClient();
    await start();
    accounts.setAccounts([
      _makeAccount('alice', 'h1'),
      _makeAccount('bob', 'h2'),
    ]);
    await _settle();

    expect(relay.tips, hasLength(2));
    expect(relay.tips.map((t) => t.account), ['alice@h1', 'bob@h2']);
    for (final tip in relay.tips) {
      expect(tip.count, 3);
      expect(tip.tippedAt, tippedAt);
      expect(tip.sku, 'supporter.tip.small');
    }
    expect(store.record.syncedToServer, isTrue);
  });

  test('markTipped (同期済み): 増分 count=1 を全アカウントへ送る', () async {
    store = _MemoryStore(
      SupporterRecord(
        firstTippedAt: DateTime.utc(2026, 3, 1),
        tipCount: 1,
        syncedToServer: true,
      ),
    );
    relay = _FakeRelayClient();
    await start();
    accounts.setAccounts([_makeAccount('alice', 'h1')]);
    await _settle();
    relay.tips.clear(); // 起動時同期ぶんを除外（synced 済みなので 0 のはず）

    await container
        .read(supporterStatusProvider.notifier)
        .markTipped(sku: 'supporter.tip.big');
    await _settle();

    expect(store.record.tipCount, 2);
    expect(relay.tips, hasLength(1));
    expect(relay.tips.single.count, 1);
    expect(relay.tips.single.sku, 'supporter.tip.big');
    expect(relay.tips.single.tippedAt, isNull); // 増分はサーバー時刻に任せる
  });

  test('連続ログイン race: A 照会中に B を追加しても B の採用を取りこぼさない (#701)', () async {
    // ローカルは非サポーター。B (bob) だけが他端末で投げ銭済み。
    relay = _GatedRelayClient();
    relay.serverRecords['bob@h2'] = {
      'first_tipped_at': '2026-02-02 00:00:00',
      'tip_count': 1,
    };
    await start();

    // A をログイン → _adoptFromServer([alice]) が alice の照会で gate 待ちに入る。
    accounts.setAccounts([_makeAccount('alice', 'h1')]);
    await _settle();
    expect(container.read(isSupporterProvider), isFalse); // まだ照会中

    // alice 照会中に B を追加。旧実装ではこの同期要求が _syncing で破棄され、
    // _syncedAccountCount=1 に固定されて B は再起動まで照会されなかった。
    accounts.setAccounts([
      _makeAccount('alice', 'h1'),
      _makeAccount('bob', 'h2'),
    ]);
    await _settle();

    // gate を開けて 1 本目を完走 → 予約された再周回で [alice, bob] を再照会し
    // bob のサーバーレコードを採用する。
    (relay as _GatedRelayClient).release();
    await _settle();

    expect(container.read(isSupporterProvider), isTrue);
    expect(store.record.firstTippedAt!.toUtc(), DateTime.utc(2026, 2, 2));
    expect(store.record.syncedToServer, isTrue);
  });

  test(
    '連続ログイン race (backfill 経路): バックフィル中に B を追加しても B にも行き渡る (#701)',
    () async {
      // ローカル先行・未同期のサポーター。バックフィル送信が走る。
      store = _MemoryStore(
        SupporterRecord(
          firstTippedAt: DateTime.utc(2026, 3, 1),
          tipCount: 2,
          lastSku: 'supporter.tip.small',
        ),
      );
      relay = _GatedRelayClient();
      await start();

      // A をログイン → _uploadToServer([alice]) が最初の tip 送信で gate 待ち。
      accounts.setAccounts([_makeAccount('alice', 'h1')]);
      await _settle();
      expect(store.record.syncedToServer, isFalse); // まだバックフィル中

      // バックフィル中に B を追加。旧実装ではこの後 synced=true が確定し、
      // 再周回が synced 枝に落ちて bob を取りこぼした。
      accounts.setAccounts([
        _makeAccount('alice', 'h1'),
        _makeAccount('bob', 'h2'),
      ]);
      await _settle();

      // gate 解放 → alice の tip 完走 → アカウント増を検知して synced 確定を
      // 見送り、再周回で [alice, bob] を再アップロードする。
      (relay as _GatedRelayClient).release();
      await _settle();

      final tipped = relay.tips.map((t) => t.account).toSet();
      expect(tipped, containsAll(['alice@h1', 'bob@h2']));
      expect(store.record.syncedToServer, isTrue);
    },
  );

  test('relay 不通: ローカル値で degrade し、未同期のまま例外も出ない', () async {
    store = _MemoryStore(
      SupporterRecord(firstTippedAt: DateTime.utc(2026, 3, 1), tipCount: 1),
    );
    relay = _FakeRelayClient()..failing = true;
    await start();
    accounts.setAccounts([_makeAccount('alice', 'h1')]);
    await _settle();

    expect(container.read(isSupporterProvider), isTrue); // ローカル値は生きる
    expect(store.record.syncedToServer, isFalse); // 次回再同期に委ねる
  });

  test('backfill 失敗時は同期済み登録を見送り、次のアカウント変化で再試行する (#724)', () async {
    // 同期済み (syncedToServer=true) レコードで _uploadToServer の backfill 枝に
    // 入る。relay 失敗を握り潰して synced 登録すると、不通復帰後も再試行されない。
    store = _MemoryStore(
      SupporterRecord(
        firstTippedAt: DateTime.utc(2026, 3, 1),
        tipCount: 1,
        syncedToServer: true,
      ),
    );
    relay = _FakeRelayClient()..failing = true;
    await start();
    accounts.setAccounts([_makeAccount('alice', 'h1')]);
    await _settle();
    expect(relay.tips, isEmpty); // 不通で送れていない

    // relay 復帰。同じアカウント集合の再 emit で listener を再評価させる。
    // 失敗時に alice を「同期済み」と登録していなければ（#724 修正）、
    // alice は未同期のまま listener が発火し、バックフィルが再試行される。
    relay.failing = false;
    accounts.setAccounts([_makeAccount('alice', 'h1')]);
    await _settle();

    expect(relay.tips.map((t) => t.account), contains('alice@h1'));
  });
}
