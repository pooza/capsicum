import 'package:dio/dio.dart';

/// モロヘイヤが返す 409 の機械可読な `code` (#1176・mulukhiya#4579・5.38.0〜)。
///
/// 仕様の正本はモロヘイヤの `docs/api.md`「競合 (409)」節。
///
/// ⚠⚠ **判定に `error` の文言を使わない。**文言は予告なく推敲される。5.37.x 以前は
/// `code` が無く文言でしか区別できなかったが、**`code` の無い 409 は従来どおり
/// 「再試行は無駄」として扱う**のが安全（[mulukhiyaConflictCode] が null を返す）。
enum MulukhiyaConflict {
  /// 書き込みロックの競合（投稿テンプレートの作成・更新・削除 / 番組表の編集）。
  ///
  /// **一過性なので再試行してよい。**`Retry-After`（秒）が付く。
  locked,

  /// 番組表の自動更新が有効。**再試行は無駄**（設定を変えるまで通らない）。
  autoUpdate,

  /// 番組表のキーが既にある。**再試行は無駄**（入力を変える）。
  duplicateKey,

  /// 投稿テンプレートが上限に達している。**再試行は無駄**（どれかを消す）。
  templateLimit,

  /// Annict の同じ記録・レビューが直前に送られている。
  ///
  /// ⚠⚠ **そのまま送り直してはいけない。**冪等性ロックは**先の要求が成功すると
  /// TTL（既定 30 秒）まで残る**ので、待って送り直すと**先の要求が成功していた
  /// 場合に二重に記録される**。⚠ 「少し待って再試行」の文面を出さないこと。
  duplicateRequest,
}

/// [error] が 409 なら、その `code` を返す。
///
/// **409 でない / `code` が無い（5.37.x 以前・上流の 409 の透過）/ 未知の `code` は
/// null。**null は「再試行は無駄」として扱う（従来の挙動）。
///
/// ⚠ 未知の `code` を null に倒すのは forward-compatible にするため。新しい版が
/// 足した `code` を古いクライアントが読んでも、従来の扱いに落ちるだけで壊れない。
MulukhiyaConflict? mulukhiyaConflictCode(Object error) {
  if (error is! DioException) return null;
  final response = error.response;
  if (response?.statusCode != 409) return null;
  final data = response?.data;
  if (data is! Map) return null;
  return switch (data['code']) {
    'locked' => MulukhiyaConflict.locked,
    'auto_update' => MulukhiyaConflict.autoUpdate,
    'duplicate_key' => MulukhiyaConflict.duplicateKey,
    'template_limit' => MulukhiyaConflict.templateLimit,
    'duplicate_request' => MulukhiyaConflict.duplicateRequest,
    _ => null,
  };
}

/// ロックの競合で待てる秒数（`Retry-After`）。付いていなければ null。
///
/// ⚠ [MulukhiyaConflict.locked] 以外には付かない。
int? mulukhiyaRetryAfterSeconds(Object error) {
  if (error is! DioException) return null;
  final raw = error.response?.headers.value('retry-after');
  return raw == null ? null : int.tryParse(raw.trim());
}

/// Annict への記録・感想が 409 になったときの文面 (#1176)。
///
/// ⚠⚠ **`duplicate_request` では送り直しを促さない。**「少し待って再試行」と出すと、
/// **先の要求が成功していた場合に利用者が二重に記録してしまう**。
String annictConflictMessage(MulukhiyaConflict? code) => switch (code) {
  MulukhiyaConflict.duplicateRequest =>
    '直前に同じ内容を送っています。Annict で記録されているか確認してください',
  MulukhiyaConflict.locked => '別の処理と重なりました。少し待ってからもう一度お試しください',
  _ => 'Annict への投稿に失敗しました',
};
