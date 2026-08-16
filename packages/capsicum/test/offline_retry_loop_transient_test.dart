import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #974 の回帰テスト。
///
/// **眼目は「画面の文言どおり自動で再試行が回っていること」。**
///
/// `_OfflineHomeScaffold` は「アカウントは保持したまま自動で再試行を続ける」と
/// 表示するが、#959 で足した transient 経路（Keychain ロックで `getSecrets` が
/// 読めなかった分）は、secret を抱えて回る旧ループに構造上載せられなかった。
/// 結果、**全アカウントが Keychain ロックで落ちた起動では定期ループが 1 本も
/// 回らず**、復帰契機が resume と手動ボタンだけになっていた。常駐で前面に
/// 来ないまま解錠された場合、無期限にオフライン画面のままになりうる。
///
/// ループが回っていることは「時間の経過とともに `getSecrets` が繰り返し
/// 読み直されること」で観測する。Keychain の再読み込みは解錠の検知手段その
/// ものなので、これが止まっている＝自動復帰が効かない、と同義になる。
class _MockStorage extends Mock implements AccountStorage {}

void main() {
  const key = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );
  final keyStr = key.toStorageKey();

  /// ramp-up (2 / 5 / 15 / 30 秒) をすべて消化するのに足りる時間。
  final rampUpTotal = kOfflineRetryRampUp.reduce((a, b) => a + b);

  _MockStorage lockedStorage() {
    final storage = _MockStorage();
    when(() => storage.getAccountKeys()).thenAnswer((_) async => [keyStr]);
    when(
      () => storage.getSecrets(keyStr),
    ).thenThrow(const TransientSecretUnavailableException('keychain locked'));
    return storage;
  }

  test('Keychain ロックだけで落ちた起動でも、定期再試行ループが回る', () {
    fakeAsync((async) {
      final storage = lockedStorage();
      final container = ProviderContainer(
        overrides: [accountStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      container.read(accountManagerProvider.notifier).restoreSessions();
      async.flushMicrotasks();

      // 起動時の 1 回だけ読まれた状態。ここでループが無いのが #974 の症状。
      verify(() => storage.getSecrets(keyStr)).called(1);
      expect(
        container
            .read(accountManagerProvider)
            .offlineAccounts
            .map((o) => o.key),
        [key],
        reason: 'オフライン保持自体は #959 のとおり効いている',
      );

      // ramp-up を消化するぶん進めると、周回のたびに読み直しているはず。
      async.elapse(rampUpTotal);
      verify(
        () => storage.getSecrets(keyStr),
      ).called(kOfflineRetryRampUp.length);

      // 立ち上がり後も定常間隔で回り続ける（打ち切らない・#938）。
      async.elapse(kOfflineRetrySteadyInterval * 3);
      verify(() => storage.getSecrets(keyStr)).called(3);

      // ループを止めてから抜ける（fakeAsync に保留タイマーを残さない）。
      container.dispose();
      async.elapse(kOfflineRetrySteadyInterval * 2);
    });
  });

  test('解錠されれば、次の周回で secret を読み直せる', () {
    fakeAsync((async) {
      final storage = lockedStorage();
      final container = ProviderContainer(
        overrides: [accountStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      container.read(accountManagerProvider.notifier).restoreSessions();
      async.flushMicrotasks();
      clearInteractions(storage);

      // 解錠された（= 以降は secret が消えている扱いにして、probe まで進まずに
      // 決着させる）。null は「secret が本当に無い」経路で、offline から drop
      // される。⚠ ここで見たいのは **ロック解除を検知できること** であって
      // 復元の成否ではない。ネットワーク probe はこのテストの範囲外。
      when(() => storage.getSecrets(keyStr)).thenAnswer((_) async => null);

      async.elapse(kOfflineRetryRampUp.first);
      async.flushMicrotasks();

      verify(() => storage.getSecrets(keyStr)).called(1);
      expect(
        container.read(accountManagerProvider).offlineAccounts,
        isEmpty,
        reason: '読み直せた結果 secret 消失と判明したので offline から落ちる',
      );

      // 対象が空になったのでループも終わる。以降は読み直しが起きない。
      async.elapse(kOfflineRetrySteadyInterval * 3);
      verifyNever(() => storage.getSecrets(keyStr));
    });
  });

  test('オフライン保持が 1 件も無ければループは起きない', () {
    fakeAsync((async) {
      final storage = _MockStorage();
      when(() => storage.getAccountKeys()).thenAnswer((_) async => []);

      final container = ProviderContainer(
        overrides: [accountStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      container.read(accountManagerProvider.notifier).restoreSessions();
      async.flushMicrotasks();
      async.elapse(kOfflineRetrySteadyInterval * 3);

      verifyNever(() => storage.getSecrets(any()));
    });
  });
}
