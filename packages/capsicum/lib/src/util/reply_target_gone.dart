import 'package:dio/dio.dart';

import 'misskey_api_error.dart';

/// 投稿の失敗が「返信先の投稿が消えている」ためかどうか (#1113)。
///
/// 削除して再編集で引き継いだ返信先が、その間に消えていることがある。サーバーは
/// どちらも存在しない返信先を拒否するので、**返信のままでは送れない**。
///
/// | サーバー | 返り方 |
/// | --- | --- |
/// | Misskey | 400 + `error.code == 'NO_SUCH_REPLY_TARGET'` |
/// | Mastodon | 404（`statuses_controller.rb` の `set_thread`） |
///
/// ⚠ **Mastodon の 404 は引用元の消失と区別できない。**`set_quoted_status` も
/// 同じ 404 を返す（`set_thread` が先に走るので、返信先が消えていればそちらが
/// 勝つが、返信先が生きていて引用元が消えた場合も 404 になる）。本文は
/// 翻訳済みの文言なので照合できない。⚠ **引用を含む送信では決めつけない**
/// （[sentWithQuote]）。外すと、返信をやめても送れない案内を出してしまう。
bool isReplyTargetGoneError(
  Object error, {
  required bool sentAsReply,
  required bool sentWithQuote,
}) {
  if (!sentAsReply) return false;
  if (error is! DioException) return false;
  final code = misskeyApiErrorCode(error);
  if (code != null) return code == 'NO_SUCH_REPLY_TARGET';
  return error.response?.statusCode == 404 && !sentWithQuote;
}
