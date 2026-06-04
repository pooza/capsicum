/// 投稿・メッセージ・通知の日時表示を組み立てるユーティリティ。
///
/// 絶対表示（`2026-03-26 12:34`）か相対表示（`3分前`）かは
/// display_settings の `absoluteTimeProvider` で切り替わる。各画面が
/// 同じロジックを重複実装していたものをここに集約した（#557）。
library;

/// 絶対時刻表示（`YYYY-MM-DD HH:mm`、端末ローカルタイムゾーン）。
String formatAbsoluteTime(DateTime time) {
  final local = time.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// 相対時刻表示（`3分前` 等）。`time` は UTC である前提。
String formatRelativeTime(DateTime time) {
  final diff = DateTime.now().toUtc().difference(time);
  if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
  if (diff.inHours < 24) return '${diff.inHours}時間前';
  if (diff.inDays < 30) return '${diff.inDays}日前';
  final months = diff.inDays ~/ 30;
  if (months < 12) return '$monthsヶ月前';
  return '${diff.inDays ~/ 365}年前';
}

/// `absoluteTimeProvider` の値に応じて絶対/相対を切り替える。
String formatTimestamp(DateTime time, {required bool absolute}) =>
    absolute ? formatAbsoluteTime(time) : formatRelativeTime(time);
