/// 番組表エントリの放送日時を、実況タグセット一覧に出す 1 つの文字列へ畳む
/// (#965)。
///
/// タグセットを選ぶのは実況の直前なので、**当日・翌日だけ「今日」「明日」へ
/// 置き換え、それ以遠は `M/d`** にする。日付境界の判定はローカル日付で行う
/// (モロヘイヤの `next_on` は時刻を持たない `YYYY-MM-DD` で、時差を持ち込むと
/// 「今日」が 1 日ズレる)。
///
/// ⚠ **`nextOn` が null の枠は、日付を出さない** (#986)。
///
/// #965 ではここを「毎日」と表記していた。値の欠落ではないことを示す意図
/// だったが、**放送日を持たないことと毎日放送であることは違う**ので取りやめた
/// （#965 の判断の反転。次に読んだ人が「空欄だと情報が欠けて見える」と考えて
/// 戻さないよう、経緯ごとここに残す）。
///
/// 日付が無く時刻だけある枠は時刻のみ (`22:00`)、どちらも無ければ空文字を返す。
/// 呼び出し側 (`compose_screen` の `_programSublabel`) は `isNotEmpty` で
/// ガードしているので、空文字なら要素ごと落ちる。
String programScheduleLabel({
  required DateTime? nextOn,
  required String? startTime,
  required DateTime now,
}) {
  final datePart = _datePart(nextOn, now);
  if (startTime == null) return datePart;
  if (datePart.isEmpty) return startTime;
  return '$datePart $startTime';
}

String _datePart(DateTime? nextOn, DateTime now) {
  if (nextOn == null) return '';
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(nextOn.year, nextOn.month, nextOn.day);
  final days = date.difference(today).inDays;
  return switch (days) {
    0 => '今日',
    1 => '明日',
    _ => '${date.month}/${date.day}',
  };
}
