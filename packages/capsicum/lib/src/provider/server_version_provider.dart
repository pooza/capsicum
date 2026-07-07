import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/server_version_checker.dart';
import 'account_manager_provider.dart';

/// 現在のサーバーの software 名と本家 latest への追従状況 (#815 続き)。
///
/// nodeinfo（software 名・版）+ GitHub の本家 latest を 1 回問い合わせ、結果は
/// セッション中キャッシュされる（`FutureProvider`。アカウント切替で再取得）。
/// 取得失敗・非対応ソフトは `null`。UI は追従表示を出さないだけで素の版表示に戻る。
final serverVersionStatusProvider = FutureProvider<ServerVersionStatus?>((
  ref,
) async {
  final host = ref.watch(currentAccountProvider)?.key.host;
  if (host == null) return null;
  return ServerVersionChecker.check(host);
});
