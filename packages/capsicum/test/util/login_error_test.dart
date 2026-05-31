import 'dart:io';

import 'package:capsicum/src/util/login_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyLoginFailure', () {
    test('Keychain errSecInteractionNotAllowed (-25308) → secureStorage', () {
      final r = classifyLoginFailure(
        PlatformException(
          code: '-25308',
          message: 'errSecInteractionNotAllowed',
        ),
      );
      expect(r.kind, LoginFailureKind.secureStorage);
      expect(r.message, 'ログイン情報の保存に失敗しました');
    });

    test('Keychain (message のみで判定) → secureStorage', () {
      final r = classifyLoginFailure(
        PlatformException(code: 'Unexpected', message: 'Keychain error'),
      );
      expect(r.kind, LoginFailureKind.secureStorage);
    });

    test('Keychain と無関係な PlatformException → unknown', () {
      final r = classifyLoginFailure(
        PlatformException(
          code: 'no_activity',
          message: 'no foreground activity',
        ),
      );
      expect(r.kind, LoginFailureKind.unknown);
      expect(r.message, 'ログインに失敗しました');
    });

    test('DioException connectionError → network', () {
      final r = classifyLoginFailure(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.connectionError,
        ),
      );
      expect(r.kind, LoginFailureKind.network);
      expect(r.message, '通信に失敗しました');
    });

    test('DioException connectionTimeout → network', () {
      final r = classifyLoginFailure(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.connectionTimeout,
        ),
      );
      expect(r.kind, LoginFailureKind.network);
    });

    test('DioException badResponse (サーバー応答あり) → server', () {
      final r = classifyLoginFailure(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(path: '/'),
            statusCode: 500,
          ),
        ),
      );
      expect(r.kind, LoginFailureKind.server);
      expect(r.message, 'サーバーがエラーを返しました');
    });

    test('SocketException (Failed host lookup) → network', () {
      final r = classifyLoginFailure(
        const SocketException('Failed host lookup'),
      );
      expect(r.kind, LoginFailureKind.network);
    });

    test('未分類の例外 → unknown', () {
      final r = classifyLoginFailure(StateError('boom'));
      expect(r.kind, LoginFailureKind.unknown);
      expect(r.message, 'ログインに失敗しました');
    });
  });
}
