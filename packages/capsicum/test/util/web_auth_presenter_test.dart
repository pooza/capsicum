import 'dart:io';

import 'package:capsicum/src/util/web_auth_presenter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1260: iOS で、ログインのキャンセル直後の自動のやり直しが必ず落ちていた。
///
/// 閉じかけの認証シートが残っている間、プラグインは
/// `ACQUIRE_ROOT_VIEW_CONTROLLER_FAILED` を即座に返す。待てば開ける。
void main() {
  PlatformException busy() => PlatformException(
    code: 'ACQUIRE_ROOT_VIEW_CONTROLLER_FAILED',
    message: 'Failed to acquire root view controller',
  );

  group('isWebAuthPresenterBusy', () {
    test('土台が空いていない失敗だけを拾う', () {
      expect(isWebAuthPresenterBusy(busy()), isTrue);
    });

    test('⚠ キャンセルや通信失敗は拾わない（待っても結果が変わらない）', () {
      expect(
        isWebAuthPresenterBusy(
          PlatformException(code: 'CANCELED', message: 'User canceled login'),
        ),
        isFalse,
      );
      expect(isWebAuthPresenterBusy(const SocketException('x')), isFalse);
      expect(
        isWebAuthPresenterBusy(
          StateError('ACQUIRE_ROOT_VIEW_CONTROLLER_FAILED'),
        ),
        isFalse,
        reason: '文字列ではなく PlatformException の code で見る',
      );
    });
  });

  group('openWebAuthWhenPresenterReady', () {
    test('1 回で開ければ待たない', () {
      fakeAsync((async) {
        var calls = 0;
        String? result;
        openWebAuthWhenPresenterReady(() async {
          calls++;
          return 'capsicum://oauth?code=x';
        }).then((v) => result = v);
        async.flushMicrotasks();
        expect(calls, 1);
        expect(result, 'capsicum://oauth?code=x');
      });
    });

    test('🔴 キャンセル直後は開けない → 待って開き直すと通る', () {
      fakeAsync((async) {
        var calls = 0;
        final retries = <int>[];
        String? result;
        openWebAuthWhenPresenterReady(() async {
          calls++;
          // 最初の 2 回は、閉じかけのシートに阻まれる。
          if (calls <= 2) throw busy();
          return 'ok';
        }, beforeRetry: retries.add).then((v) => result = v);

        async.flushMicrotasks();
        expect(calls, 1, reason: '同じ瞬間には開き直さない');
        expect(result, isNull);

        async.elapse(const Duration(milliseconds: 400));
        expect(calls, 2);
        async.elapse(const Duration(milliseconds: 400));
        expect(calls, 3);
        expect(result, 'ok');
        expect(retries, [2, 3]);
      });
    });

    test('待っても開けなければ、最後の失敗をそのまま投げる', () {
      fakeAsync((async) {
        var calls = 0;
        Object? error;
        openWebAuthWhenPresenterReady<String>(() async {
          calls++;
          throw busy();
        }, maxAttempts: 3).catchError((Object e) {
          error = e;
          return '';
        });
        async.elapse(const Duration(seconds: 5));
        expect(calls, 3, reason: '回数の上限で止まる（回り続けない）');
        expect(isWebAuthPresenterBusy(error!), isTrue);
      });
    });

    test('⚠ キャンセルでは開き直さない', () {
      fakeAsync((async) {
        var calls = 0;
        Object? error;
        openWebAuthWhenPresenterReady<String>(() async {
          calls++;
          throw PlatformException(code: 'CANCELED');
        }).catchError((Object e) {
          error = e;
          return '';
        });
        async.elapse(const Duration(seconds: 5));
        expect(calls, 1);
        expect((error! as PlatformException).code, 'CANCELED');
      });
    });

    test('⚠ 待っている間に追い越されたら、開き直さずに止まる', () {
      fakeAsync((async) {
        var calls = 0;
        Object? error;
        openWebAuthWhenPresenterReady<String>(() async {
          calls++;
          throw busy();
        }, beforeRetry: (_) => throw StateError('superseded')).catchError((
          Object e,
        ) {
          error = e;
          return '';
        });
        async.elapse(const Duration(seconds: 5));
        expect(calls, 1, reason: '古い試行のシートを出さない');
        expect(error, isA<StateError>());
      });
    });
  });
}
