import 'dart:async';
import 'dart:io';

import 'package:capsicum/src/service/secure_storage_gate.dart';
import 'package:capsicum/src/service/secure_storage_health.dart';
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

  // #1141: Linux のキーリングの失敗を「ログインに失敗しました」に落とさない。
  group('classifyLoginFailure — Linux のキーリング (#1141)', () {
    void expectKeyring(Object error) {
      final r = classifyLoginFailure(error);
      expect(r.kind, LoginFailureKind.secureStorage, reason: '$error');
      expect(r.message, contains('キーリング / Secret Service'));
    }

    test('関所が触って上限に達した（2026-09-17 の実測の形）', () {
      // 関所が実際に投げるメッセージで作る。形を二重に書くと片方だけ変わる。
      expectKeyring(
        TimeoutException(
          SecureStorageGate.timeoutMessage('write'),
          const Duration(seconds: 5),
        ),
      );
    });

    test('触る前の疎通確認で諦めた', () {
      expectKeyring(TimeoutException(SecureStorageHealth.probeSkipMessage));
    });

    test('libsecret が断った / プラグイン内部の失敗', () {
      expectKeyring(
        PlatformException(
          code: 'Libsecret error',
          message: 'Failed to unlock the keyring',
        ),
      );
      expectKeyring(PlatformException(code: 'StorageError', message: 'x'));
    });

    test('ロックされている → 解錠を促す', () {
      final r = classifyLoginFailure(
        PlatformException(code: 'KeyringLocked', message: 'KeyringLocked'),
      );
      expect(r.kind, LoginFailureKind.secureStorage);
      expect(r.message, contains('ロックされている'));
      expect(r.message, contains('解錠'));
    });

    test('⚠ 関所以外の TimeoutException はキーリングのせいにしない', () {
      for (final e in [
        TimeoutException('Future not completed'),
        TimeoutException(null),
        // 形が似ていても、関所の語彙でなければ拾わない。
        TimeoutException('secure storage write timed out after retry'),
      ]) {
        expect(classifyLoginFailure(e).kind, LoginFailureKind.unknown);
      }
    });

    test('⚠ Apple の Keychain の文言は変えない', () {
      final r = classifyLoginFailure(
        PlatformException(
          code: '-25308',
          message: 'errSecInteractionNotAllowed',
        ),
      );
      expect(r.message, 'ログイン情報の保存に失敗しました');
    });

    test('⚠ 復元の扱いは変わらない（キーリングの失敗でアカウントを消さない側）', () {
      expect(
        classifyRestoreFailure(
          TimeoutException(SecureStorageHealth.probeSkipMessage),
        ),
        RestoreOutcome.giveUp,
      );
    });
  });

  group('classifyRestoreFailure (#792)', () {
    DioException badResponse(int code) => DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/'),
        statusCode: code,
      ),
    );

    test('ネットワーク不通 → retriable', () {
      expect(
        classifyRestoreFailure(const SocketException('Failed host lookup')),
        RestoreOutcome.retriable,
      );
      expect(
        classifyRestoreFailure(
          DioException(
            requestOptions: RequestOptions(path: '/'),
            type: DioExceptionType.connectionError,
          ),
        ),
        RestoreOutcome.retriable,
      );
    });

    test('サーバー 5xx（再構築中など） → retriable', () {
      expect(
        classifyRestoreFailure(badResponse(500)),
        RestoreOutcome.retriable,
      );
      expect(
        classifyRestoreFailure(badResponse(503)),
        RestoreOutcome.retriable,
      );
    });

    test('401 / 403（認証失効） → authRevoked', () {
      expect(
        classifyRestoreFailure(badResponse(401)),
        RestoreOutcome.authRevoked,
      );
      expect(
        classifyRestoreFailure(badResponse(403)),
        RestoreOutcome.authRevoked,
      );
    });

    test('その他 4xx → giveUp', () {
      expect(classifyRestoreFailure(badResponse(404)), RestoreOutcome.giveUp);
      expect(classifyRestoreFailure(badResponse(400)), RestoreOutcome.giveUp);
    });

    test('secure storage 失敗 → giveUp', () {
      expect(
        classifyRestoreFailure(
          PlatformException(
            code: '-25308',
            message: 'errSecInteractionNotAllowed',
          ),
        ),
        RestoreOutcome.giveUp,
      );
    });

    test('未分類の例外 → giveUp', () {
      expect(classifyRestoreFailure(StateError('boom')), RestoreOutcome.giveUp);
    });
  });
}
