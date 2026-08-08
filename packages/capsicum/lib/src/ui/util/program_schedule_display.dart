/// 番組表エントリの放送日時を、実況タグセット一覧に出す 1 つの文字列へ畳む
/// (#965)。
///
/// タグセットを選ぶのは実況の直前なので、**当日・翌日だけ「今日」「明日」へ
/// 置き換え、それ以遠は `M/d`** にする。日付境界の判定はローカル日付で行う
/// (モロヘイヤの `next_on` は時刻を持たない `YYYY-MM-DD` で、時差を持ち込むと
/// 「今日」が 1 日ズレる)。
///
/// **`nextOn` が null の枠は「毎日」**であって、値の欠落ではない。モロヘイヤ
/// 側で `next_on` を持たないエントリは `program.ics` でも毎日扱いになる。
/// 空欄にすると「情報が欠けている」ように見えるため、明示的に出す。
///
/// 日時をまったく出せない場合 (`nextOn` も `startTime` も無い、はありえない —
/// `nextOn` が無ければ「毎日」になる) は空文字を返す。
String programScheduleLabel({
  required DateTime? nextOn,
  required String? startTime,
  required DateTime now,
}) {
  final datePart = _datePart(nextOn, now);
  if (startTime == null) return datePart;
  return '$datePart $startTime';
}

String _datePart(DateTime? nextOn, DateTime now) {
  if (nextOn == null) return '毎日';
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(nextOn.year, nextOn.month, nextOn.day);
  final days = date.difference(today).inDays;
  return switch (days) {
    0 => '今日',
    1 => '明日',
    _ => '${date.month}/${date.day}',
  };
}
