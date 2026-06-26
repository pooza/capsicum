import 'dart:async';

import 'package:sentry_flutter/sentry_flutter.dart';

/// 起動計測 (#716) を Sentry Performance に出すための薄いヘルパ。
///
/// 計測値は呼び出し時点で確定しているので、[durationMs] ぶん遡った開始時刻で
/// transaction を起こし、即 finish して「そのフェーズ 1 本」の transaction として
/// 記録する。breadcrumb はイベント発生時にしか送信されず集計もできないが、
/// transaction なら `tracesSampleRate=1.0` の下で Performance に出て、平均 / p95 /
/// タグ絞り込み（既読位置復元 ON/OFF 等）ができる。
///
/// [measurementsMs] はミリ秒値（fetch / enrich / since_launch 等）。[tags] は
/// 低カーディナリティの絞り込み軸（restore_read_position / found / jumped）。
/// [data] は件数など（accounts / posts / fetches）。
///
/// **契約（#743）**: [tags] / [data] には host / token / username など PII /
/// クレデンシャルを渡さないこと。transaction は `beforeSend` を通らず、保険の
/// `beforeSendTransaction` も sensitive キー名（host/token/secret 等）の tag を
/// filter するだけで、任意キーに入った値や [data] までは追えない。低カーディ
/// ナリティの bool / 件数のみに留めること。
void recordStartupPhase(
  String name, {
  required int durationMs,
  Map<String, num> measurementsMs = const {},
  Map<String, String> tags = const {},
  Map<String, Object?> data = const {},
}) {
  final now = DateTime.now();
  final tx = Sentry.startTransaction(
    name,
    'app.start',
    startTimestamp: now.subtract(Duration(milliseconds: durationMs)),
  );
  measurementsMs.forEach(
    (k, v) => tx.setMeasurement(
      k,
      v,
      unit: DurationSentryMeasurementUnit.milliSecond,
    ),
  );
  tags.forEach(tx.setTag);
  data.forEach(tx.setData);
  unawaited(tx.finish(endTimestamp: now));
}
