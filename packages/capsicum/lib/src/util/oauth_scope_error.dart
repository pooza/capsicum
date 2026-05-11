import 'package:dio/dio.dart';

/// OAuth トークンのスコープ不足エラーを判定する。
///
/// 新機能追加で OAuth スコープが増えたとき（例: #248 の Misskey chat 機能で
/// `read:chat` / `write:chat` を追加）、既存トークンには新スコープが含まれ
/// ないため対応 API 呼び出しが 401 / 403 で失敗する。再ログインで OAuth フロー
/// を回せば直るが、ユーザーに「再ログインしてください」を伝えるためにエラーを
/// 識別する必要がある (#441)。
///
/// 検出ルール:
///
/// - **Mastodon**: HTTP 401 + ボディに `"error": "insufficient_scope"` または
///   `WWW-Authenticate` ヘッダに `insufficient_scope`
/// - **Misskey**: HTTP 403 + ボディ `error.code` が `PERMISSION_DENIED` /
///   `NO_AUTH_SCOPE` / `PERMISSION_DENIED_ERROR` (Misskey は同種のエラーを
///   複数のキーで返すことがあるため幅広に拾う)
///
/// false positive を完全には避けられない（例: Misskey の `PERMISSION_DENIED`
/// はブロックされた相手への操作等でも返るため、再ログインで解決しないケースに
/// 「再ログインしてください」表示が出る可能性はある）。ただし「再ログインしても
/// 治らない」UX の劣化と「scope エラーをそのまま見せる」UX の劣化のトレードオフ
/// では、後者の方が深刻なので前者寄りに倒している。
bool isOAuthScopeError(Object error) {
  if (error is! DioException) return false;
  final status = error.response?.statusCode;
  if (status == 401) {
    final data = error.response?.data;
    if (data is Map && data['error'] == 'insufficient_scope') return true;
    // WWW-Authenticate: Bearer error="insufficient_scope" scope="..."
    final wwwAuth = error.response?.headers.value('www-authenticate');
    if (wwwAuth != null && wwwAuth.toLowerCase().contains('insufficient_scope')) {
      return true;
    }
  }
  if (status == 403) {
    final data = error.response?.data;
    if (data is Map) {
      final inner = data['error'];
      if (inner is Map) {
        final code = inner['code'];
        if (code == 'PERMISSION_DENIED' ||
            code == 'NO_AUTH_SCOPE' ||
            code == 'PERMISSION_DENIED_ERROR') {
          return true;
        }
      }
    }
  }
  return false;
}
