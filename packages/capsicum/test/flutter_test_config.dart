import 'dart:async';

import 'package:capsicum/src/platform/platform_info.dart';

/// テスト全体の前提をそろえる（`flutter test` が各テストファイルの前に読む）。
///
/// ## 全キーが 1 項目に入る OS の書き直し（#1387）は、既定で切る
///
/// [storesSecretsInSharedItem] は Linux で true になり、secure storage の
/// 書き込みのたびに [SharedItemWriteVerifier] が読み戻して書き直す。
/// ⚠⚠ **書き直しの控えは 1 プロセスに 1 つ**（本番で 4 つの店が 1 項目を
/// 共有するため）なので、テストでは**前のテストの偽物で控えたキーが、次の
/// テストの偽物へ書き直される**（`push_relay_id_cleanup_test` で実際に踏んだ）。
/// しかも Linux の CI と macOS の手元で結果が変わる。
///
/// だから既定は false にして、書き直しを見るテスト
/// （`secure_storage_shared_item_test`）だけが true にする。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugSharedSecretItemOverride = false;
  await testMain();
}
