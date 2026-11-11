import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// ストリーミングの切断（`timeline.stream.disconnected`）を、**アプリ全体で
/// 1 つの窓口から間引いて** Sentry へ送る (#1378)。
///
/// 切断の記録は #788 で入れた観測用の計器で（info・不具合の報告ではない）、
/// close code と host の分布を見るためのもの。v2.0 が広まってから件数が跳ね、
/// 2026-10-12〜11-11 の課金期間には Sentry 組織の Errors の約 9 割を capsicum が
/// 使い、その大半がこの記録だった（利用者 2 人で 14 日に 5,414 件という
/// イシューもあった）。
///
/// - ⚠⚠ **以前はタイムラインの購読ごとに 60 秒の間引きを持っていた。**デッキは
///   同じサーバーへカラムの数だけ接続するので、1 回切れると**カラムの数だけ**
///   送られていた。間引きを**ホストごと・アプリ全体で 1 つ**にする（間隔は従来
///   どおり [quiet]）
/// - 間引きを通った記録のうち、[sampleRate] の割合だけを送る。分布を見る目的は
///   割合で落としても保てる。⚠ 間引きは**送らなかった回にも掛ける**（送る数の
///   上限を「ホストごとに 1 分 1 回 × [sampleRate]」で読めるようにするため）
/// - 送るときは `timeline.stream.sample_rate` タグに割合を残す（件数から元の
///   規模を推定するとき用）
/// - ⚠ **fingerprint は変えない**（`['timeline.stream.disconnected', code]`）。
///   既存のイシュー（CAPSICUM-37 / 3C / 3D 等）へ積まれ続け、件数の変化を
///   そのまま比べられる
/// - closeReason はサーバー任意の文字列を持ちうるので、中身は載せず有無だけ
///   （#788 から引き継ぎ）。host で挙動は分岐しない（#826 から引き継ぎ）
class StreamDisconnectReporter {
  StreamDisconnectReporter({
    this.quiet = const Duration(seconds: 60),
    this.sampleRate = defaultSampleRate,
    void Function(StreamDisconnectEvent event)? send,
    DateTime Function()? now,
    double Function()? random,
  }) : assert(sampleRate >= 0 && sampleRate <= 1),
       _send = send ?? _sendToSentry,
       _now = now ?? DateTime.now,
       _random = random ?? Random().nextDouble;

  /// 送る割合の既定値。
  static const defaultSampleRate = 0.1;

  /// 1 度扱ったあと、同じホストの切断を扱わない長さ。
  final Duration quiet;

  /// 間引きを通った切断のうち、送る割合（0〜1）。
  final double sampleRate;

  final void Function(StreamDisconnectEvent event) _send;
  final DateTime Function() _now;
  final double Function() _random;

  /// ホストごとの、最後に扱った時刻。ホストが分からない接続は `null` のキー。
  final Map<String?, DateTime> _lastHandledAt = {};

  /// 切断を 1 件報告する。
  ///
  /// [host] は接続先（分かるときだけ。⚠ 生の URL やトークンは渡さない）。
  void report({String? host, int? closeCode, String? closeReason}) {
    final now = _now();
    final last = _lastHandledAt[host];
    if (last != null && now.difference(last) < quiet) return;
    _lastHandledAt[host] = now;
    // 古い記録を残さない（接続先は増減する）。
    _lastHandledAt.removeWhere((_, at) => now.difference(at) >= quiet);
    if (_random() >= sampleRate) return;
    _send(
      StreamDisconnectEvent(
        host: host,
        closeCode: closeCode?.toString() ?? 'none',
        hasReason: closeReason != null && closeReason.isNotEmpty,
        sampleRate: sampleRate,
      ),
    );
  }

  /// 記録を捨てる（テスト用）。
  @visibleForTesting
  void reset() => _lastHandledAt.clear();

  static void _sendToSentry(StreamDisconnectEvent event) {
    Sentry.captureMessage(
      'timeline.stream.disconnected',
      level: SentryLevel.info,
      withScope: (scope) {
        scope.setTag('timeline.stream', 'disconnected');
        final host = event.host;
        if (host != null) scope.setTag('timeline.stream.host', host);
        scope.setTag('timeline.stream.close_code', event.closeCode);
        scope.setTag('timeline.stream.has_reason', event.hasReason.toString());
        scope.setTag(
          'timeline.stream.sample_rate',
          event.sampleRate.toString(),
        );
        scope.fingerprint = ['timeline.stream.disconnected', event.closeCode];
      },
    );
  }
}

/// 送る 1 件ぶんの中身。
@immutable
class StreamDisconnectEvent {
  const StreamDisconnectEvent({
    required this.host,
    required this.closeCode,
    required this.hasReason,
    required this.sampleRate,
  });

  final String? host;

  /// close code（無ければ `none`）。
  final String closeCode;

  /// closeReason が付いていたか（中身は載せない）。
  final bool hasReason;

  final double sampleRate;
}

/// アプリ全体で 1 つ。⚠ **購読ごとに作らない**（カラムの数だけ送る形へ戻る）。
final streamDisconnectReporter = StreamDisconnectReporter();
