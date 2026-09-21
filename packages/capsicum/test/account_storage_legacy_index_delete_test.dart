import 'dart:async';

import 'package:capsicum/src/service/account_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1144: 旧索引（secure storage 側）の削除が投げても、`getAccountKeys` は
/// アカウントを返す。
///
/// ⚠ 以前は削除が `try` の外にあり、関所が `TimeoutException` を投げると
/// `getAccountKeys()` ごと投げていた。`restoreSessions` が落ちて**アカウント 0 件
/// のままホームに着き**、Sentry には何も上がらない。
class _LegacyIndexStorage extends FlutterSecureStorage {
  _LegacyIndexStorage(this.legacy);

  final String? legacy;
  int deletes = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => key == 'capsicum_account_keys' ? legacy : null;

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes++;
    throw TimeoutException('secure storage delete timed out');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('⚠ 移行後の旧索引の削除が投げても、アカウントを返す', () async {
    final storage = _LegacyIndexStorage('["mastodon://a@h"]');

    final keys = await AccountStorage(storage).getAccountKeys();

    expect(keys, ['mastodon://a@h']);
    expect(storage.deletes, 1, reason: '消しに行ってはいる（検査が空振りしていない）');
  });

  test('⚠ 壊れた旧索引の削除が投げても、空で返る（投げない）', () async {
    final storage = _LegacyIndexStorage('not json');

    final keys = await AccountStorage(storage).getAccountKeys();

    expect(keys, isEmpty);
    expect(storage.deletes, 1);
  });
}
