import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/offline_account.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_test/flutter_test.dart';

/// #967: 「未接続」と「到達不能」を [OfflineAccount] の中で区別する。
///
/// ⚠ **区別が要るのは復帰手段が違うから。**到達不能は待てば背景リトライで戻る
/// が、secret 消失は待っても戻らず、ユーザーがログインし直すしかない。混ぜると
/// (a) UI が「再試行中…」と嘘をつき、(b) 戻る見込みの無い相手に getSecrets を
/// 永久に打ち続ける。
///
/// この設計を選んだ理由（#967 の A/B/C）は [OfflineAccount] の doc を参照。
/// 要点は **未接続アカウントを `Account` にしない**こと — adapter もトークンも
/// 無いので `List<Account>` の消費側は 1 箇所も触らずに済む。
void main() {
  const key = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );

  test('既定は到達不能で、背景リトライの対象になる', () {
    const offline = OfflineAccount(key: key);

    expect(offline.reason, OfflineAccountReason.unreachable);
    expect(offline.recoverableByRetry, isTrue);
    expect(offline.retrying, isTrue);
  });

  test('secretMissing は背景リトライの対象外で、retrying を立てない', () {
    const offline = OfflineAccount.secretMissing(key: key);

    expect(offline.reason, OfflineAccountReason.secretMissing);
    expect(
      offline.recoverableByRetry,
      isFalse,
      reason: 'トークンが無いので probe すら組み立てられない',
    );
    expect(offline.retrying, isFalse, reason: '「再試行中…」と出ると、待っていれば直ると誤解させる');
  });

  /// `copyWith` は `retrying` しか変えない。理由まで変わると、到達不能扱いの
  /// まま secret 消失の相手をループへ戻してしまう。
  test('copyWith は理由を保つ', () {
    const offline = OfflineAccount.secretMissing(key: key);

    final updated = offline.copyWith(retrying: true);

    expect(updated.reason, OfflineAccountReason.secretMissing);
    expect(
      updated.recoverableByRetry,
      isFalse,
      reason: 'copyWith で理由が落ちるとループの除外条件をすり抜ける',
    );
  });

  test('handle は profile が無くても出せる', () {
    expect(const OfflineAccount(key: key).handle, '@alice@mstdn.example');
    expect(
      const OfflineAccount.secretMissing(key: key).handle,
      '@alice@mstdn.example',
      reason: '理由が変わっても切替 UI のラベルは同じ',
    );
  });
}
