import 'dart:io';

import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/util/login_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #989 の回帰テスト。
///
/// **眼目は「時間を使っていない失敗だけ」を即時リトライ対象にすること。**
/// 起動直後はプロセスのネットワークスタックが立ち上がりきっておらず、
/// `connect(2)` がタイムアウトを待たずに失敗する窓がある。2026-08-18 の観測では
/// 150 ms の間に 6 アカウント中 5 件がこれで offline へ落ち、その 213 ms 後には
/// 同じホストへ到達できていた。
///
/// 対象を広げると（timeout まで拾う等）、本当に不通のときに起動が余計に遅くなる。
/// [restoreSessions] は全アカウントを並列 probe しているので、待ちは全体に効く。
void main() {
  final options = RequestOptions(path: '/api/v1/accounts/verify_credentials');

  group('isImmediateConnectFailure (#989)', () {
    test('connectionError は対象（観測された実際の型）', () {
      expect(
        isImmediateConnectFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: const SocketException('Connection failed'),
          ),
        ),
        isTrue,
      );
    });

    test('unknown でも中身が SocketException なら対象', () {
      expect(
        isImmediateConnectFailure(
          DioException(
            requestOptions: options,
            error: const SocketException('Failed host lookup'),
          ),
        ),
        isTrue,
      );
    });

    test('素の SocketException も対象', () {
      expect(
        isImmediateConnectFailure(const SocketException('Failed host lookup')),
        isTrue,
      );
    });

    test('⚠ timeout 系は対象外（既に待っているので待ち直す意味がない）', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      ]) {
        expect(
          isImmediateConnectFailure(
            DioException(requestOptions: options, type: type),
          ),
          isFalse,
          reason: '$type を即時リトライすると、不通時の起動がさらに遅くなる',
        );
      }
    });

    test('⚠ badResponse は対象外（サーバーには届いている）', () {
      expect(
        isImmediateConnectFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: options, statusCode: 503),
          ),
        ),
        isFalse,
        reason: '5xx は背景再試行の担当。300ms 後に直っている見込みは薄い',
      );
    });

    test('⚠ badCertificate / cancel は対象外', () {
      for (final type in [
        DioExceptionType.badCertificate,
        DioExceptionType.cancel,
      ]) {
        expect(
          isImmediateConnectFailure(
            DioException(requestOptions: options, type: type),
          ),
          isFalse,
        );
      }
    });

    test('unknown でも中身がネットワーク由来でなければ対象外', () {
      expect(
        isImmediateConnectFailure(
          DioException(
            requestOptions: options,
            error: const FormatException('broken json'),
          ),
        ),
        isFalse,
      );
    });
  });

  group('kInitialProbeRetryDelay (#989)', () {
    test('観測された復帰（213ms）より後に置く', () {
      expect(
        kInitialProbeRetryDelay >= const Duration(milliseconds: 213),
        isTrue,
        reason: '実測の復帰より手前で試すと、直っていないうちに 2 度目を使い切る',
      );
    });

    test('⚠ ramp-up の初回より十分短い（あちらの代わりではない）', () {
      expect(
        kInitialProbeRetryDelay < kOfflineRetryRampUp.first,
        isTrue,
        reason: 'ramp-up と同程度まで延ばすなら、この経路を足す意味がない',
      );
    });

    test('起動を目に見えて遅らせない範囲に収める', () {
      expect(
        kInitialProbeRetryDelay <= const Duration(milliseconds: 500),
        isTrue,
      );
    });
  });
}
