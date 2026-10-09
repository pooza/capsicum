import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/service/sentry_op_failure.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1246: 複数アカウントへ同時に問い合わせた取得の失敗を、まとめて報告する。
///
/// ⚠⚠ **回線が切れた 1 回で、アカウントの数だけ error を送らない。**
/// （`CAPSICUM-61`・通知の一括取得が、圏外の瞬間に接続中のサーバーの数だけ
/// 送っていた）
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

Account _account(String host) => Account(
  key: AccountKey(type: BackendType.mastodon, host: host, username: 'me'),
  adapter: _Adapter(),
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);

DioException _connectionError() => DioException(
  requestOptions: RequestOptions(path: '/api/v2/notifications'),
  type: DioExceptionType.connectionError,
);

DioException _serverError(int status) {
  final options = RequestOptions(path: '/api/v2/notifications');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<void>(requestOptions: options, statusCode: status),
  );
}

void main() {
  ({List<String> each, List<int> networkDown}) run(
    List<(String, Object)> failures, {
    required int total,
  }) {
    final each = <String>[];
    final networkDown = <int>[];
    reportFanOutFailures(
      tagKey: 'notification.list',
      operation: 'unified_fetch',
      failures: [
        for (final (host, error) in failures)
          (account: _account(host), error: error, stackTrace: StackTrace.empty),
      ],
      totalAccounts: total,
      sendEach:
          ({
            required tagKey,
            required operation,
            required error,
            required stackTrace,
            account,
          }) => each.add(account!.key.host),
      sendNetworkDown: networkDown.add,
    );
    return (each: each, networkDown: networkDown);
  }

  test('⚠⚠ 全アカウントが回線で落ちた回は、まとめて 1 件', () {
    final result = run([
      ('a', _connectionError()),
      ('b', _connectionError()),
      ('c', _connectionError()),
    ], total: 3);

    expect(result.networkDown, [3]);
    expect(result.each, isEmpty, reason: '以前はアカウントの数だけ error が飛んでいた');
  });

  test('⚠⚠ 一部だけ落ちた回は、1 件ずつ送る（そのサーバーの障害の合図）', () {
    final result = run([('b', _connectionError())], total: 3);

    expect(result.each, ['b']);
    expect(result.networkDown, isEmpty);
  });

  test('⚠ 全員が落ちていても、応答のある失敗が混ざっていればまとめない', () {
    final result = run([
      ('a', _connectionError()),
      ('b', _serverError(503)),
    ], total: 2);

    expect(result.each, ['a', 'b']);
    expect(result.networkDown, isEmpty);
  });

  test('アカウントが 1 つなら、まとめない（回線側と見分けられない）', () {
    final result = run([('a', _connectionError())], total: 1);

    expect(result.each, ['a']);
    expect(result.networkDown, isEmpty);
  });

  test('失敗が無ければ何も送らない', () {
    final result = run(const [], total: 3);

    expect(result.each, isEmpty);
    expect(result.networkDown, isEmpty);
  });

  group('回線の事象かの判定', () {
    test('応答を受け取る前の失敗は true', () {
      expect(isConnectionLevelFailure(_connectionError()), isTrue);
      expect(
        isConnectionLevelFailure(
          DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.connectionTimeout,
          ),
        ),
        isTrue,
      );
      // `CAPSICUM-61` の実物の形（type=unknown・応答なし）。
      expect(
        isConnectionLevelFailure(
          DioException(requestOptions: RequestOptions()),
        ),
        isTrue,
      );
    });

    test('⚠ 応答のある失敗（4xx / 5xx）は false', () {
      expect(isConnectionLevelFailure(_serverError(500)), isFalse);
      expect(isConnectionLevelFailure(_serverError(401)), isFalse);
    });

    test('Dio 以外の例外は false', () {
      expect(isConnectionLevelFailure(StateError('x')), isFalse);
      expect(isConnectionLevelFailure(const FormatException('x')), isFalse);
    });
  });
}
