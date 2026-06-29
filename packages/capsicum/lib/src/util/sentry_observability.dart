/// 起動計測 transaction（operation `app.start`）のサンプリングレート（#743）。
///
/// 起動ごとに `app.startup.*` が 3 本（restore / home_timeline / marker_restore）
/// 発生するため、本番ユーザー数 × 起動回数 × 3 で transaction volume が膨らむ。
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
