import 'package:dio/dio.dart';

import '../../util/misskey_api_error.dart';
import '../../util/upstream_error_message.dart';

/// 投稿アクション (リアクション・お気に入り・ブースト等) の失敗時に
/// ユーザー向けに表示するメッセージを生成する。
///
/// post_tile / notification_tile 等の複数箇所で使い回すため共通化 (#395)。
///
/// **この関数を呼ぶ catch では、必ず `Sentry.captureException` に
/// `phase` タグを付けること。** 値は投稿アクション（お気に入り / ブースト /
/// ブックマーク / ピン留め / 取り消し / タグ変更 / 別垢ブースト等）なら
/// `post_action`、リアクションの付け外しなら `reaction_add`。
///
/// 導線名（`touch_action` 等）を値にしてはいけない。`phase` は**操作の種類**を
/// 表す軸で、同じ操作がアクションシート・タッチ操作行・通知タイルの 3 導線から
/// 実行されるため、導線名にすると同じ失敗が別系列に散って母数が取れなくなる。
///
/// この規約は各 catch のコメントに散っていて新しい catch を書くときに辿り着けず、
/// v1.53 のリリース前レビューで 3 巡連続（3 / 4 / 5 巡目）で取りこぼしが出た。
/// 追加の catch を書くときはここを見ること。
///
/// ## ステータス別の分岐規約
///
/// - **400 + Misskey の `error.code`**: [misskeyErrorReason] で既知コードを日本語の
///   理由に訳す（#886 で用意した表を再利用）。チャンネルへのリノート (#895) が返す
///   `CANNOT_RENOTE_OUTSIDE_OF_CHANNEL` / `NO_SUCH_CHANNEL` や、その他のブースト
///   不可・対象消失系の 400 がここで拾える (#923)。未知コードは表に無いので下の
///   汎用文言へ倒れる。
/// - **403**: 権限・再ログイン系。Misskey 固有コードより一般的な案内を優先する。
/// - **500**: サーバー内部エラー。
String describePostActionError(Object e) {
  if (e is DioException) {
    final statusCode = e.response?.statusCode;
    if (statusCode == 400) {
      final code = misskeyApiErrorCode(e);
      if (code != null) {
        final reason = misskeyErrorReason(code);
        if (reason != null) return reason;
      }
    }
    if (statusCode == 403) {
      return '権限がありません。再ログインが必要な場合があります';
    }
    if (statusCode == 500) {
      return 'サーバー内部エラーが発生しました。サーバー管理者にお問い合わせください';
    }
  }
  return '操作に失敗しました';
}
