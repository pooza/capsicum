import 'package:capsicum_core/capsicum_core.dart';

/// お知らせの掲載期間の文字列 (#1214)。期間の指定が無ければ null。
///
/// ⚠ 終日のお知らせも、Web と同じく端末のローカルで日付を計算する（2026-10-13
/// pooza）。Web の表示を見て入力を調整している管理者のお知らせが、capsicum で
/// だけずれないようにするため。
String? announcementPeriodLabel(Announcement announcement) {
  final start = announcement.startsAt?.toLocal();
  final end = announcement.endsAt?.toLocal();
  final allDay = announcement.allDay;
  String format(DateTime t) => allDay ? _date(t) : '${_date(t)} ${_time(t)}';

  if (start == null && end == null) return null;
  if (end == null) return '${format(start!)} から';
  if (start == null) return '${format(end)} まで';
  if (_date(start) == _date(end)) {
    if (allDay) return _date(start);
    return '${format(start)} 〜 ${_time(end)}';
  }
  return '${format(start)} 〜 ${format(end)}';
}

String _date(DateTime t) => '${t.year}/${t.month}/${t.day}';

String _time(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
