import 'package:capsicum/src/ui/util/program_schedule_display.dart';
import 'package:flutter_test/flutter_test.dart';

/// #965: 実況タグセット一覧に出す放送日時ラベル。
void main() {
  // 2026-08-09 (日) 12:00 を「今」として固定する。
  final now = DateTime(2026, 8, 9, 12);

  group('programScheduleLabel (#965)', () {
    test('当日は「今日」', () {
      expect(
        programScheduleLabel(
          nextOn: DateTime(2026, 8, 9),
          startTime: '08:30',
          now: now,
        ),
        '今日 08:30',
      );
    });

    test('翌日は「明日」', () {
      expect(
        programScheduleLabel(
          nextOn: DateTime(2026, 8, 10),
          startTime: '20:00',
          now: now,
        ),
        '明日 20:00',
      );
    });

    test('2 日以降は M/d', () {
      expect(
        programScheduleLabel(
          nextOn: DateTime(2026, 8, 12),
          startTime: '19:30',
          now: now,
        ),
        '8/12 19:30',
      );
    });

    test('年をまたいでも M/d のまま（番組表は先の予定を持たない）', () {
      expect(
        programScheduleLabel(
          nextOn: DateTime(2027, 1, 3),
          startTime: '08:30',
          now: now,
        ),
        '1/3 08:30',
      );
    });

    test('過去日も M/d で出す（更新されていない枠を隠さない）', () {
      expect(
        programScheduleLabel(
          nextOn: DateTime(2026, 8, 2),
          startTime: '08:30',
          now: now,
        ),
        '8/2 08:30',
      );
    });

    test('next_on が無い枠は「毎日」', () {
      expect(
        programScheduleLabel(nextOn: null, startTime: null, now: now),
        '毎日',
      );
      expect(
        programScheduleLabel(nextOn: null, startTime: '22:00', now: now),
        '毎日 22:00',
      );
    });

    test('start_time だけ落ちても日付は出す', () {
      expect(
        programScheduleLabel(
          nextOn: DateTime(2026, 8, 9),
          startTime: null,
          now: now,
        ),
        '今日',
      );
    });

    test('「今日」の判定はローカル日付で行う（時刻の遠近に引きずられない）', () {
      // 当日の 23:59 でも「今日」、翌日の 00:01 は「明日」。UTC 換算で判定すると
      // ここが 1 日ズレる。
      expect(
        programScheduleLabel(
          nextOn: DateTime(2026, 8, 9),
          startTime: '23:59',
          now: DateTime(2026, 8, 9, 0, 1),
        ),
        '今日 23:59',
      );
      expect(
        programScheduleLabel(
          nextOn: DateTime(2026, 8, 10),
          startTime: '00:01',
          now: DateTime(2026, 8, 9, 23, 59),
        ),
        '明日 00:01',
      );
    });
  });
}
