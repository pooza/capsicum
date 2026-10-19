import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../model/account.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/exception_scrub.dart';

/// Annict 系（エピソードブラウザ・連携・記録・感想）の失敗を、release ビルドでも
/// 「どこへ・何番で」失敗したか後から分かるように残す (#1310)。
///
/// ⚠⚠ **#1305 の切り分けに debug ビルドでの再現が要った。**エピソードブラウザと
/// 連携の catch は `debugLogException` しか呼んでおらず、記録の画面は 5xx しか
/// Sentry に上げていなかった。デッキのカラムから開くと別サーバーのモロヘイヤを
/// 叩いて 403 / 404 になっていたが、release では何も残らなかった。
///
/// - **breadcrumb は必ず残す**（状態コード・ホスト・scrub 済みの例外＝パス）。
///   次に何かのイベントが上がったとき、その手前に並ぶ
/// - **イベントにするかは [annictFailureIsEvent]**。⚠ 401 / 403（未連携・
///   トークン失効）はイベントにしない既存の判断を崩さない（通常運用のノイズ）
void reportAnnictFailure(
  String operation,
  Object error,
  StackTrace stackTrace, {
  Account? account,
}) {
  final status = error is DioException ? error.response?.statusCode : null;
  try {
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: 'annict.op',
        message: operation,
        level: SentryLevel.warning,
        data: {
          'status': status ?? '-',
          'host': account?.key.host ?? '-',
          // ⚠ 例外から値を直接取り出さない。scrub 済みの形
          // （`DioException <種別> status=<番号> path=<パス>`・クエリと機密の
          // セグメントは落ちる）にしてから載せる。
          'error': scrubException(error).toString(),
        },
      ),
    );
  } catch (_) {
    // Sentry 失敗で UI を止めない。
  }
  if (!annictFailureIsEvent(error)) return;
  reportOpFailure(
    tagKey: 'annict.op',
    operation: operation,
    error: error,
    stackTrace: stackTrace,
    account: account,
    tags: {if (status != null) 'http.status': '$status'},
  );
}

/// Sentry のイベントにする失敗か (#1310)。
///
/// | 失敗 | イベント | 理由 |
/// | --- | --- | --- |
/// | 401 / 403 | しない | 未連携・トークン失効・スコープ不足（モロヘイヤが auth 系を 403 に寄せる）。通常運用 |
/// | 409 | しない | 冪等性ロック（`duplicate_request`・#1176）。画面が扱う正常系 |
/// | 状態コードの無い Dio の失敗 | しない | 回線の失敗（接続できない・タイムアウト）。回線側の事象 |
/// | それ以外の状態コード（404・5xx ほか） | する | #1305 の 404 のように、行き先の取り違えやサーバーの異常 |
/// | Dio 以外の例外 | する | 応答の形が合わないなど、アプリ側の不具合 |
@visibleForTesting
bool annictFailureIsEvent(Object error) {
  if (error is! DioException) return true;
  final status = error.response?.statusCode;
  if (status == null) return false;
  return status != 401 && status != 403 && status != 409;
}
