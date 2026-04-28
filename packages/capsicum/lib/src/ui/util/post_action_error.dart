import 'package:dio/dio.dart';

/// 投稿アクション (リアクション・お気に入り・ブースト等) の失敗時に
/// ユーザー向けに表示するメッセージを生成する。
///
/// post_tile / notification_tile 等の複数箇所で使い回すため共通化 (#395)。
String describePostActionError(Object e) {
  if (e is DioException) {
    final statusCode = e.response?.statusCode;
    if (statusCode == 403) {
      return '権限がありません。再ログインが必要な場合があります';
    }
    if (statusCode == 500) {
      return 'サーバー内部エラーが発生しました。サーバー管理者にお問い合わせください';
    }
  }
  return '操作に失敗しました';
}
