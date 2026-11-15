import 'dart:async';

import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/secret_service_probe.dart';

/// テスト全体の前提をそろえる（`flutter test` が各テストファイルの前に読む）。
///
/// ## 全キーが 1 項目に入る OS の書き直し（#1387）は、既定で切る
///
/// [storesSecretsInSharedItem] は Linux で true になり、secure storage の
/// 書き込みのたびに `SharedItemWriteVerifier` が読み戻して書き直す。
/// ⚠⚠ **書き直しの控えは 1 プロセスに 1 つ**（本番で 4 つの店が 1 項目を
/// 共有するため）なので、テストでは**前のテストの偽物で控えたキーが、次の
/// テストの偽物へ書き直される**（`push_relay_id_cleanup_test` で実際に踏んだ）。
/// しかも Linux の CI と macOS の手元で結果が変わる。
///
/// だから既定は false にして、書き直しを見るテスト
/// （`secure_storage_shared_item_test`）だけが true にする。
///
/// ## キーリングのロックの問い合わせ（#1386）は、既定で「ロックされていない」
///
/// オフラインの自動の再試行は、Linux では読む前に
/// [SecretServiceProbe.isLocked] で本物の D-Bus に問い合わせる。⚠⚠ **テストの
/// 中で本物に問い合わせると、`fakeAsync` の中では通信が終わらず、再試行の
/// ループが進まない**（`offline_retry_loop_transient_test` が inori で落ちた・
/// Mac では Linux の分岐を通らないので緑のまま）。結果も手元のキーリングの
/// 状態で変わる。ロックの振る舞いを見るテスト
/// （`offline_retry_locked_keyring_test`）は `debugLockedOverride` で上書きする。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugSharedSecretItemOverride = false;
  SecretServiceProbe.debugLockedFallback = () async => false;
  await testMain();
}
