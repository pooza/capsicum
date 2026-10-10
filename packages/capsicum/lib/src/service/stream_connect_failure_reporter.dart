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

  /// 複数のホストが同時に落ちた ＝ 回線側の事象と読む。
  bool get looksLikeNetworkDown => hosts.length >= 2;
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
/// - 送ったあと [quiet] のあいだは送らない（切断中の連発を抑える・従来の
///   購読ごとの間引きと同じ長さ）
///
/// ⚠ breadcrumb は呼ぶ側が毎回残す（ここは「イベントにするか」だけを決める）。
class StreamConnectFailureReporter {
  StreamConnectFailureReporter({
    this.window = const Duration(seconds: 5),
    this.quiet = const Duration(seconds: 60),
    void Function(StreamConnectFailureBatch batch)? send,
    DateTime Function()? now,
  }) : _send = send ?? _sendToSentry,
       _now = now ?? DateTime.now;

  /// 同時に起きた失敗をまとめる窓。
  final Duration window;

  /// 送ったあと、次を送らない長さ。
  final Duration quiet;

  final void Function(StreamConnectFailureBatch batch) _send;
  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _lastSentAt;

  String? _category;
  Object? _error;
  StackTrace? _stackTrace;
  final Set<String> _hosts = {};
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
    final lastSentAt = _lastSentAt;
    if (lastSentAt != null && _now().difference(lastSentAt) < quiet) return;
    _count++;
    if (host != null) _hosts.add(host);
    if (_timer != null) return;
    _category = category;
    _error = error;
    _stackTrace = stackTrace;
    _timer = Timer(window, _flush);
  }

  void _flush() {
    _timer = null;
    final category = _category;
    final error = _error;
    if (category == null || error == null) return;
    final batch = StreamConnectFailureBatch(
      category: category,
      error: error,
      stackTrace: _stackTrace,
      hosts: Set.of(_hosts),
      connectionCount: _count,
    );
    _category = null;
    _error = null;
    _stackTrace = null;
    _hosts.clear();
    _count = 0;
    _lastSentAt = _now();
    _send(batch);
  }

  /// 待っているぶんを捨てる（テスト用）。
  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _lastSentAt = null;
    _category = null;
    _error = null;
    _stackTrace = null;
    _hosts.clear();
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
