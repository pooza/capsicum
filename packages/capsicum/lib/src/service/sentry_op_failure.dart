import 'package:sentry_flutter/sentry_flutter.dart';

import '../model/account.dart';
import '../util/exception_scrub.dart';

/// chat / drive / pages 等の UI 操作失敗を Sentry に流す共通ヘルパ (#625)。
///
/// 集約理由:
/// - DioException の生 URL / Authorization が `event.exceptions[].value` に
///   乗らないよう [scrubException] を一律に通す (#499 同型の漏れ予防)
/// - プリセット host 優先で観測する運用 (feedback_sentry_preset_server_priority)
///   のため `host` / `backend` tag を必ず付ける。account 不在経路は `-` で詰める
/// - Sentry SDK 自体の失敗で UI 更新を止めない
///
/// [tagKey] は経路の系統 (`chat.op` / `drive.op` / `pages.op` /
/// `chat.load_more` 等) を、[operation] は個別の操作名 (`send_message` /
/// `load_liked` 等) を指す。fingerprint は両方 + 例外型で組む。
/// [tags] は fingerprint に含めない補助タグ（例: Play の未実装キー `Ui:C:switch`）。
/// issue は集約したまま、Sentry UI 上でタグ別に件数比較・絞り込みできる (#875)。
void reportOpFailure({
  required String tagKey,
  required String operation,
  required Object error,
  required StackTrace stackTrace,
  Account? account,
  Map<String, String>? tags,
}) {
  try {
    Sentry.captureException(
      scrubException(error),
      stackTrace: stackTrace,
      withScope: (scope) {
        scope.setTag(tagKey, operation);
        scope.setTag('host', account?.key.host ?? '-');
        scope.setTag('backend', account?.key.type.name ?? '-');
        if (tags != null) {
          for (final entry in tags.entries) {
            scope.setTag(entry.key, entry.value);
          }
        }
        scope.fingerprint = [tagKey, operation, error.runtimeType.toString()];
      },
    );
  } catch (_) {
    // Sentry 失敗で UI 更新を止めない
  }
}
