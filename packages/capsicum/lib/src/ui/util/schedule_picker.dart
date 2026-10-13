import 'package:flutter/material.dart';

/// 予約投稿の時刻として受け付ける、いまからの最短の間隔。
///
/// Mastodon はこれより手前の時刻を 422 で拒む。Misskey の下限は「未来である
/// こと」だけだが、選んでから送るまでに過ぎてしまう時刻を通さないよう揃える。
const kScheduleMinLeadTime = Duration(minutes: 5);

/// [scheduled] が予約投稿の時刻として早すぎるか。
bool isScheduleTooSoon(DateTime scheduled, {DateTime? now}) =>
    scheduled.isBefore((now ?? DateTime.now()).add(kScheduleMinLeadTime));

/// 予約投稿の日時を選ばせる（日付 → 時刻の順）。
///
/// 投稿画面の予約と、予約投稿一覧の「時刻を変更」(#1212) が共有する。途中で
/// やめたら null。早すぎる時刻を選んだら、その旨を出して null。
///
/// [initial] は最初に指しておく日時（いまの予約）。無ければ 1 時間後。
Future<DateTime?> pickScheduleDateTime(
  BuildContext context, {
  DateTime? initial,
}) async {
  final now = DateTime.now();
  final fallback = now.add(const Duration(hours: 1));
  // ⚠ いまの予約が過去になっていても、日付の下限（今日）より前を指さない。
  final start = initial != null && initial.isAfter(now) ? initial : fallback;
  final messenger = ScaffoldMessenger.of(context);
  final date = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: now,
    lastDate: now.add(const Duration(days: 365)),
    helpText: '予約投稿の日付',
    confirmText: '次へ（時刻を選択）',
  );
  if (date == null || !context.mounted) return null;

  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(start),
    helpText: '予約投稿の時刻',
  );
  if (time == null) return null;

  final scheduled = DateTime(
    date.year,
    date.month,
    date.day,
    time.hour,
    time.minute,
  );
  if (isScheduleTooSoon(scheduled)) {
    messenger.showSnackBar(const SnackBar(content: Text('5分以上先の日時を指定してください')));
    return null;
  }
  return scheduled;
}
