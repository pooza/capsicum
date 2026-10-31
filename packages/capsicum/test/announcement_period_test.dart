import 'package:capsicum/src/ui/util/announcement_period.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1214: お知らせの掲載期間の出し方。
void main() {
  Announcement announcement({
    DateTime? startsAt,
    DateTime? endsAt,
    bool allDay = false,
  }) => Announcement(
    id: '1',
    content: '',
    publishedAt: DateTime(2026),
    startsAt: startsAt,
    endsAt: endsAt,
    allDay: allDay,
  );

  final start = DateTime(2026, 11, 3, 9, 5);
  final sameDayEnd = DateTime(2026, 11, 3, 21, 0);
  final laterEnd = DateTime(2026, 11, 5, 21, 0);

  test('⚠ 指定が無ければ何も出さない', () {
    expect(announcementPeriodLabel(announcement()), isNull);
    expect(announcementPeriodLabel(announcement(allDay: true)), isNull);
  });

  test('片方だけなら「から」「まで」', () {
    expect(
      announcementPeriodLabel(announcement(startsAt: start)),
      '2026/11/3 09:05 から',
    );
    expect(
      announcementPeriodLabel(announcement(endsAt: laterEnd)),
      '2026/11/5 21:00 まで',
    );
  });

  test('両方あれば範囲で出し、同じ日なら日付を繰り返さない', () {
    expect(
      announcementPeriodLabel(announcement(startsAt: start, endsAt: laterEnd)),
      '2026/11/3 09:05 〜 2026/11/5 21:00',
    );
    expect(
      announcementPeriodLabel(
        announcement(startsAt: start, endsAt: sameDayEnd),
      ),
      '2026/11/3 09:05 〜 21:00',
    );
  });

  test('⚠ 終日は時刻を出さない', () {
    expect(
      announcementPeriodLabel(
        announcement(startsAt: start, endsAt: laterEnd, allDay: true),
      ),
      '2026/11/3 〜 2026/11/5',
    );
    expect(
      announcementPeriodLabel(
        announcement(startsAt: start, endsAt: sameDayEnd, allDay: true),
      ),
      '2026/11/3',
    );
    expect(
      announcementPeriodLabel(announcement(endsAt: laterEnd, allDay: true)),
      '2026/11/5 まで',
    );
  });

  test('⚠ UTC の時刻は端末のローカルに直して出す（終日も同じ）', () {
    final utc = DateTime.utc(2026, 11, 3, 23, 59);
    final local = utc.toLocal();
    final date = '${local.year}/${local.month}/${local.day}';

    expect(
      announcementPeriodLabel(announcement(endsAt: utc, allDay: true)),
      '$date まで',
    );
  });

  test('既読にしても期間は残る', () {
    final copied = announcement(
      startsAt: start,
      endsAt: laterEnd,
      allDay: true,
    ).copyWith(read: true);

    expect(copied.startsAt, start);
    expect(copied.endsAt, laterEnd);
    expect(copied.allDay, isTrue);
  });
}
