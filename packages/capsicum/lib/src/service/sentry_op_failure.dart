import 'package:dio/dio.dart';
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
/// `chat.list` 等) を、[operation] は個別の操作名 (`send_message` /
/// `load_liked` 等) を指す。fingerprint は両方 + 例外型で組む。
///
/// ## [tagKey] の付け方（規約・#1083-E）
///
/// **`<領域>.op` か `<領域>.<経路>` の 2 型だけ。**`tag_key_shape_guard_test`
/// が形を機械で見ている。
///
/// ⚠ **キーにするのは「op の系統」であって「対象」ではない。**
/// `hashtag.followed`（フォロー中のタグ**という対象**）や
/// `moderation.blocks` / `moderation.mutes`（ブロック中 / ミュート中の一覧）は
/// 対象を名前にしていた。**何をしたか**は [operation] が持つので、
/// `hashtag.op` × `unfollow` / `moderation.op` × `unblock` と書く。
///
/// ⚠ **一覧の取得は経路型（`<領域>.list`）に揃える (#1117-E)。**同じ「一覧を引く」
/// 経路なのに `post_list.op` / `user_list.op` / `hashtag.list` と 2 型あり、Sentry で
/// **「一覧の取得失敗を全部見る」が 1 クエリで書けなかった**（`tagKey:*.list` で
/// 引けるようにする）。⚠ 一覧の上で行う**操作**（解除・承認等）は従来どおり
/// `<領域>.op` 側（例: `hashtag.list` で引き、`hashtag.op` で解除する）。
///
/// ⚠ **群の細かさは変わらない。**fingerprint が `[tagKey, operation, 例外型]`
/// なので、キーを畳んでも issue の数は同じ。変わるのは Sentry のファセットで
/// 「モデレーション操作の失敗を全部見る」が **1 クエリで書けるかどうか**。
/// [tags] は fingerprint に含めない補助タグ（例: Play の未実装キー `Ui:C:switch`）。
/// issue は集約したまま、Sentry UI 上でタグ別に件数比較・絞り込みできる (#875)。
/// サーバーの応答を受け取る前に落ちた失敗か（回線断・名前解決・接続の時間切れ）
/// (#1246)。
///
/// ⚠ **応答があった失敗（4xx / 5xx）は false。**あちらはサーバーが返した結果で、
/// 回線の事象ではない。
bool isConnectionLevelFailure(Object error) {
  if (error is! DioException) return false;
  if (error.response != null) return false;
  return switch (error.type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.unknown => true,
    DioExceptionType.badCertificate ||
    DioExceptionType.badResponse ||
    DioExceptionType.transformTimeout ||
    DioExceptionType.cancel => false,
  };
}

/// 複数アカウントへ同時に問い合わせた取得の失敗を、まとめて報告する (#1246)。
///
/// ⚠⚠ **全アカウントが同時に回線で落ちた回は、アカウントの数だけ送らない。**
/// 中身は回線側の事象で、1 回の圏外につき接続中のサーバーの数だけ error が
/// 飛んでいた（`CAPSICUM-61`・1 install が 2 つの瞬間に 6 ホストぶんで 10 件）。
/// warning 1 件にまとめる。
///
/// ⚠ **一部だけ落ちた回・応答のある失敗は、従来どおり 1 件ずつ送る。**
/// 「特定のサーバーだけ落ちている」はサーバー側の障害の合図になる。
/// [send] はテスト用の差し替え口。
void reportFanOutFailures({
  required String tagKey,
  required String operation,
  required List<({Account account, Object error, StackTrace stackTrace})>
  failures,
  required int totalAccounts,
  void Function({
    required String tagKey,
    required String operation,
    required Object error,
    required StackTrace stackTrace,
    Account? account,
  })?
  sendEach,
  void Function(int accounts)? sendNetworkDown,
}) {
  if (failures.isEmpty) return;
  final networkDown =
      totalAccounts >= 2 &&
      failures.length == totalAccounts &&
      failures.every((f) => isConnectionLevelFailure(f.error));
  if (networkDown) {
    if (sendNetworkDown != null) {
      sendNetworkDown(totalAccounts);
      return;
    }
    try {
      Sentry.captureMessage(
        '$tagKey.network_down',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag(tagKey, operation);
          scope.setTag('accounts', '$totalAccounts');
          scope.fingerprint = [tagKey, operation, 'network_down'];
        },
      );
    } catch (_) {
      // Sentry 失敗で UI 更新を止めない
    }
    return;
  }
  for (final f in failures) {
    (sendEach ?? reportOpFailure)(
      tagKey: tagKey,
      operation: operation,
      error: f.error,
      stackTrace: f.stackTrace,
      account: f.account,
    );
  }
}

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
