import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../util/exception_scrub.dart';

/// まとめて送る 1 件ぶんの中身。
@immutable
class StreamConnectFailureBatch {
  const StreamConnectFailureBatch({
    required this.category,
    required this.error,
    required this.stackTrace,
    required this.hosts,
    required this.connectionCount,
    this.continuesNetworkDown = false,
  });

  /// 最初に失敗した接続の種別（`timeline.stream.connect` 等）。
  final String category;

  /// 最初の失敗。
  final Object error;
  final StackTrace? stackTrace;

  /// 失敗したホスト（重複なし・ホストが分からない接続は入らない）。
  final Set<String> hosts;

  /// 窓の中で失敗した接続の本数。
  final int connectionCount;

  /// 直前のまとめが「回線側」で、その続きと読める回か (#1267)。
  ///
  /// 長い圏外では再接続の間隔が最大 60 秒まで広がり、ホストごとにずれる。
  /// 2 回目以降の窓には 1 ホストしか入らないことが多く、ホストの数だけで
  /// 判定すると、同じ圏外の続きが単一ホストの error として積まれる。
  final bool continuesNetworkDown;

  /// 複数のホストが同時に落ちた（か、その続き）＝ 回線側の事象と読む。
  bool get looksLikeNetworkDown => hosts.length >= 2 || continuesNetworkDown;
}

/// ストリーミング接続の失敗を、**アプリ全体で 1 つにまとめて** Sentry へ送る
/// (#1246)。
///
/// ⚠⚠ **以前は購読ごとに別々の間引きを持っていた。**デッキは複数のサーバーへ
/// 同時に接続する（カラムごと・通知用の接続ごと）ので、回線が 1 回切れると
/// **接続の本数だけ** error が飛んだ（4 ホスト 7 本なら 7 件）。中身は回線側の
/// 事象でアプリの不具合ではないのに、本当の error を埋もれさせ、Sentry の枠も
/// 使っていた。
///
/// - 短い窓（[window]）の中で起きた失敗を 1 件にまとめる
/// - **2 ホスト以上が同時に落ちた回は「回線側」**と読み、warning で 1 件
/// - ⚠⚠ **1 ホストだけの回は従来どおり error。**「特定のサーバーだけ引けない」
///   （回線は生きている）はサーバー側の障害の合図なので、見えるままにする。
///   種別ごとの fingerprint も変えない（既存のイシューへ積まれ続ける）
/// - 送ったあと [quiet] のあいだは、**そのホストのぶん**を送らない（切断中の
///   連発を抑える・従来の購読ごとの間引きと同じ長さ）。⚠ **窓は全体で 1 つ、
///   送らない時間はホストごと** (#1267)。以前は送らない時間もアプリ全体で 1 つ
///   だったので、ホスト A が長く落ちている間にホスト B が落ちても、B の失敗が
///   件数にもホストの集合にも入らなかった
/// - 「回線側」と読んだあと [networkDownCarryOver] のうちに来た次のまとめは、
///   1 ホストだけでも続きとして「回線側」に読む (#1267)
/// - ⚠⚠ **どこかの接続が成立したら、続きはそこで終わる**（[noteConnected]）。
///   続きとして読んだ回は次の起点になるので、失敗が 3 分より短い間隔で来る
///   かぎり鎖は切れない。回線が戻ったあとも 1 ホストだけ落ち続けていると、
///   その障害が warning に畳まれ続け、上の「見えるままにする」が破れていた
///   （v2.2 のリリース前レビュー）。接続の成立は「回線は生きている」証拠
///
/// ⚠ breadcrumb は呼ぶ側が毎回残す（ここは「イベントにするか」だけを決める）。
class StreamConnectFailureReporter {
  StreamConnectFailureReporter({
    this.window = const Duration(seconds: 5),
    this.quiet = const Duration(seconds: 60),
    this.networkDownCarryOver = const Duration(minutes: 3),
    void Function(StreamConnectFailureBatch batch)? send,
    DateTime Function()? now,
  }) : _send = send ?? _sendToSentry,
       _now = now ?? DateTime.now;

  /// 同時に起きた失敗をまとめる窓。
  final Duration window;

  /// 送ったあと、同じホストのぶんを送らない長さ。
  final Duration quiet;

  /// 「回線側」と読んだあと、次のまとめを続きとして読む長さ。
  ///
  /// ⚠ 再接続の間隔（最大 60 秒）と [quiet]（60 秒）が重なっても続きが途切れない
  /// よう、その合計より長く取る。続きとして読んだ回が、また次の起点になる。
  final Duration networkDownCarryOver;

  final void Function(StreamConnectFailureBatch batch) _send;
  final DateTime Function() _now;

  Timer? _timer;

  /// ホストごとの、最後に送った時刻。ホストが分からない接続は `null` のキー。
  final Map<String?, DateTime> _lastSentAt = {};

  /// 最後に「回線側」として送った時刻。
  DateTime? _lastNetworkDownAt;

  String? _category;
  Object? _error;
  StackTrace? _stackTrace;
  final Set<String> _hosts = {};
  bool _hostless = false;
  int _count = 0;

  /// 接続の失敗を 1 件報告する。
  ///
  /// [category] は接続の種別（`timeline.stream.connect` 等）。[host] は接続先
  /// （分かるときだけ。⚠ 生の URL やトークンは渡さない）。
  void report({
    required String category,
    required Object error,
    StackTrace? stackTrace,
    String? host,
  }) {
    final lastSentAt = _lastSentAt[host];
    if (lastSentAt != null && _now().difference(lastSentAt) < quiet) return;
    _count++;
    if (host != null) {
      _hosts.add(host);
    } else {
      _hostless = true;
    }
    if (_timer != null) return;
    _category = category;
    _error = error;
    _stackTrace = stackTrace;
    _timer = Timer(window, _flush);
  }

  /// どこかのサーバーへの接続が成立した（＝ 回線は生きている）と知らせる。
  ///
  /// 「回線側」の続きをここで終わらせる。以後に来る 1 ホストだけの失敗は、
  /// サーバー側の障害の合図として error に戻る。⚠ 呼ぶ側はホストを問わない ——
  /// 1 本でも通れば回線側の事象ではない。
  void noteConnected() => _lastNetworkDownAt = null;

  void _flush() {
    _timer = null;
    final category = _category;
    final error = _error;
    if (category == null || error == null) return;
    final now = _now();
    final lastNetworkDownAt = _lastNetworkDownAt;
    final batch = StreamConnectFailureBatch(
      category: category,
      error: error,
      stackTrace: _stackTrace,
      hosts: Set.of(_hosts),
      connectionCount: _count,
      continuesNetworkDown:
          lastNetworkDownAt != null &&
          now.difference(lastNetworkDownAt) < networkDownCarryOver,
    );
    // ⚠ 送らない時間は、このまとめに入ったホストにだけ掛ける (#1267)。
    for (final host in _hosts) {
      _lastSentAt[host] = now;
    }
    if (_hostless) _lastSentAt[null] = now;
    // 古い記録を残さない（接続先は増減する）。
    _lastSentAt.removeWhere((_, at) => now.difference(at) >= quiet);
    if (batch.looksLikeNetworkDown) _lastNetworkDownAt = now;
    _category = null;
    _error = null;
    _stackTrace = null;
    _hosts.clear();
    _hostless = false;
    _count = 0;
    _send(batch);
  }

  /// 待っているぶんを捨てる（テスト用）。
  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _lastSentAt.clear();
    _lastNetworkDownAt = null;
    _category = null;
    _error = null;
    _stackTrace = null;
    _hosts.clear();
    _hostless = false;
    _count = 0;
  }

  static void _sendToSentry(StreamConnectFailureBatch batch) {
    if (batch.looksLikeNetworkDown) {
      // 回線側。⚠ ホスト名は載せない（どのサーバーかは、この回では意味が無い）。
      Sentry.captureMessage(
        'stream.connect.network_down',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('stream.connect', 'network_down');
          scope.setTag('stream.connect.hosts', '${batch.hosts.length}');
          scope.setTag(
            'stream.connect.connections',
            '${batch.connectionCount}',
          );
          scope.fingerprint = ['stream.connect', 'network_down'];
        },
      );
      return;
    }
    Sentry.captureException(
      scrubException(batch.error),
      stackTrace: batch.stackTrace,
      withScope: (scope) {
        scope.setTag(batch.category, 'failed');
        final host = batch.hosts.firstOrNull;
        if (host != null) scope.setTag('stream.connect.host', host);
        scope.setTag('stream.connect.connections', '${batch.connectionCount}');
        // ⚠ 種別ごとの fingerprint は変えない（既存のイシューへ積まれ続ける）。
        scope.fingerprint = [
          batch.category,
          batch.error.runtimeType.toString(),
        ];
      },
    );
  }
}

/// アプリ全体で 1 つ。⚠ **購読ごとに作らない**（まとめる意味が無くなる）。
final streamConnectFailureReporter = StreamConnectFailureReporter();
