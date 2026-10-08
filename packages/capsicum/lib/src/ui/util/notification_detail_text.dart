import 'package:capsicum_core/capsicum_core.dart';

/// 書き出した対象の表示名 (#1187)。Misskey の `userExportableEntities`
/// （`packages/backend/src/types.ts`）。
///
/// ⚠⚠ **未知の値は「そのまま出す」。**上流が種類を増やしたときに「書き出しが
/// 完了しました」だけに戻すと、**何を書き出したか分からない**という元の不具合へ
/// 逆戻りする。英語でも出ているほうがまし。
const _exportedEntityLabels = <String, String>{
  'antenna': 'アンテナ',
  'blocking': 'ブロック',
  'clip': 'クリップ',
  'customEmoji': 'カスタム絵文字',
  'favorite': 'お気に入り',
  'following': 'フォロー',
  'muting': 'ミュート',
  'note': 'ノート',
  'userList': 'リスト',
};

/// [ExportCompletion.entity] の表示名 (#1187)。
String exportedEntityLabel(String entity) =>
    _exportedEntityLabels[entity] ?? entity;

/// 通知の種別固有の荷物を 1 行の説明に落とす (#1187)。載せるものが無ければ null。
///
/// ⚠⚠ **#1177 で種別名は出るようになったが、中身は空のままだった。**ここが
/// 埋まらないと「ロールが付与されました（どのロール？）」「予約投稿に失敗しま
/// した（どれ？）」のように、**読めても行動できない**通知になる。
///
/// ⚠ **`type` で分岐しない。**サーバーはその種別のときにしか荷物を載せてこない
/// ので、「入っていたら出す」で足りる。分岐を足すと、モデルに読み込んだのに
/// 画面へ出ない経路ができる（#1046 層③ で実際に見つかった型の不具合）。
String? notificationDetailText(Notification notification) {
  if (notification.assignedRole case final role?) {
    return role.name.isEmpty ? null : role.name;
  }
  if (notification.export case final export?) {
    return '${exportedEntityLabel(export.entity)}を書き出しました';
  }
  if (notification.failedScheduledPost case final failed?) {
    final text = failed.content?.trim();
    // ⚠ **本文が空の予約投稿はありうる**（添付だけ）。そのときは「どれか」を
    // 時刻で示す。⚠ `id` は出さない（利用者には意味が無い）。
    return (text == null || text.isEmpty)
        ? '${_formatScheduledAt(failed.scheduledAt)} に予約していた投稿'
        : text;
  }
  if (notification.chatInvitation case final invitation?) {
    final name = invitation.room?.name.trim();
    return (name == null || name.isEmpty) ? null : name;
  }
  if (notification.followRequestMessage case final message?) {
    final trimmed = message.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

/// 予約していた時刻（端末のローカル時刻）。⚠ **日付まで出す** —— 予約投稿は
/// 数日先を指していることがあるので、時刻だけだと特定できない。
String _formatScheduledAt(DateTime scheduledAt) {
  final local = scheduledAt.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$month/$day $hour:$minute';
}
