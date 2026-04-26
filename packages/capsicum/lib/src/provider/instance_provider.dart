import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';

/// 現在アカウントのサーバー [Instance]。最大ファイルサイズ等の事前バリデーション
/// 用に compose 系画面から参照する。
///
/// アカウント切り替え時のみ再 fetch される（adapter は account 単位の identity を
/// 持つため `ref.watch` で自動的に追従）。autoDispose しないのは、メディア添付の
/// 度に getInstance() を再呼び出ししないため（compose_screen は autoDispose 系で
/// 開く度に破棄される）。
///
/// 取得失敗時は null を返し、呼び出し側は事前チェックを丸ごとスキップする
/// （CLAUDE.md「機能不足時の通知」: 接続自体は拒否しない）。
final currentInstanceProvider = FutureProvider<Instance?>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null) return null;
  try {
    return await adapter.getInstance();
  } catch (_) {
    return null;
  }
});
