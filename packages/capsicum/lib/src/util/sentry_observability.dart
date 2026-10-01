/// 起動計測 transaction（operation `app.start`）のサンプリングレート（#743）。
///
/// 起動ごとに `app.startup.*` が最大 4 本（restore / home_timeline /
/// marker_restore / home_timeline_swap）発生するため、本番ユーザー数 ×
/// 起動回数 × 4 で transaction volume が膨らむ。
/// 平均 / p95 の集計に必要な母数は残しつつ大半を間引く。母数が見えてきたら
/// 調整する（`startup_trace.dart` の `recordStartupPhase` 参照）。
const startupTracesSampleRate = 0.2;

/// `app.start` の起動計測だけ [startupTracesSampleRate] に落とし、その他の
/// transaction は `options.tracesSampleRate`（1.0）にフォールバックさせるための
/// 判定（#743）。引数は transaction の operation 名。
///
/// `tracesSampler` コールバックの薄いラッパとして使う。Sentry の
/// `SentrySamplingContext` はバージョン間で内部構造が変わるため、ここでは
/// operation 文字列だけを受け取りテスト可能にしている。null を返すと
/// `options.tracesSampleRate` が使われる。
double? startupAwareTracesSampler(String? operation) {
  if (operation == 'app.start') {
    return startupTracesSampleRate;
  }
  return null;
}

/// lifecycle 遷移を breadcrumb として残すかの判定（#1199）。
///
/// macOS の App Hang（CAPSICUM-5V / 5W）が「表示が落ちている間に出たのか」を
/// 次のイベントで切り分けるための観測。[previous] は直前に**記録した**状態名
/// （未記録なら null）、[next] は今回の状態名（`AppLifecycleState.name`）。
///
/// ⚠⚠ **`inactive` は落とす。**デスクトップでは**ウィンドウのフォーカスを
/// 失うたび**に来る（`kUserProfileFreshnessTtl` の注記と同じ理由で、`inactive`
/// は「前面に無いが可視」）。breadcrumb は既定 100 件で打ち切られるので、
/// alt-tab のたびに 1 件積むと **push / timeline の記録を押し出す**。
///
/// ⚠ **同じ状態の連続も落とす。**復帰のたびに `resumed` が重なっても、
/// 分かることは増えない。
bool shouldRecordLifecycleBreadcrumb(String? previous, String next) {
  if (next == 'inactive') return false;
  return next != previous;
}

/// transaction の tag 値を scrub すべき sensitive なキー名か判定する（#743）。
///
/// transaction は `beforeSend`（event scrub）を通らないため、`beforeSendTransaction`
/// 側でこのガードを使って tag を filter する。現状 `recordStartupPhase` の tag は
/// 低カーディナリティの bool / 件数のみで漏洩はないが、将来 host / token / username
/// を tag に載せる呼び出しが混ざった場合の保険として許可外キーを弾く。
bool isSensitiveTagKey(String key) {
  final k = key.toLowerCase();
  return k == 'host' ||
      k == 'username' ||
      k.contains('token') ||
      k.contains('secret') ||
      k.contains('password') ||
      k.contains('credential') ||
      k.contains('authorization');
}
