import 'package:capsicum/src/util/sentry_observability.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('startupAwareTracesSampler — #743 起動計測の間引き', () {
    test('operation app.start は startupTracesSampleRate に落とす', () {
      expect(startupAwareTracesSampler('app.start'), startupTracesSampleRate);
    });

    test('その他の operation は null（options.tracesSampleRate にフォールバック）', () {
      expect(startupAwareTracesSampler('navigation'), isNull);
      expect(startupAwareTracesSampler('http.client'), isNull);
      expect(startupAwareTracesSampler('ui.load'), isNull);
      expect(startupAwareTracesSampler(null), isNull);
    });

    test('サンプリングレートは間引く意図どおり 0 < rate < 1', () {
      expect(startupTracesSampleRate, greaterThan(0));
      expect(startupTracesSampleRate, lessThan(1));
    });
  });

  group('isSensitiveTagKey — #743 transaction tag の scrub ガード', () {
    test('クレデンシャル系キーは sensitive 判定', () {
      for (final key in const [
        'host',
        'username',
        'access_token',
        'TOKEN',
        'client_secret',
        'password',
        'aws_credential',
        'Authorization',
      ]) {
        expect(isSensitiveTagKey(key), isTrue, reason: key);
      }
    });

    test('大文字小文字を無視する', () {
      expect(isSensitiveTagKey('Host'), isTrue);
      expect(isSensitiveTagKey('UserName'), isTrue);
    });

    test('低カーディナリティの計測 tag は許可（scrub しない）', () {
      for (final key in const [
        'phase',
        'restored',
        'account_count',
        'cold_start',
        'platform',
        'marker_restore',
      ]) {
        expect(isSensitiveTagKey(key), isFalse, reason: key);
      }
    });

    test('host は完全一致のみ（hostname など別語は許可）', () {
      // `host` は == 判定なので、語の一部に host を含む別キーは弾かない。
      expect(isSensitiveTagKey('host'), isTrue);
      expect(isSensitiveTagKey('hostname'), isFalse);
      expect(isSensitiveTagKey('host_count'), isFalse);
    });
  });

  group('shouldRecordLifecycleBreadcrumb — #1199 App Hang の切り分け', () {
    test('表示が落ちる側の遷移は記録する', () {
      for (final state in const ['hidden', 'paused', 'detached']) {
        expect(
          shouldRecordLifecycleBreadcrumb(null, state),
          isTrue,
          reason: state,
        );
      }
    });

    test('復帰も記録する（ハングの前後どちらかを決めるため）', () {
      expect(shouldRecordLifecycleBreadcrumb('hidden', 'resumed'), isTrue);
    });

    test('⚠ inactive は記録しない（desktop では alt-tab ごとに来る）', () {
      expect(shouldRecordLifecycleBreadcrumb(null, 'inactive'), isFalse);
      expect(shouldRecordLifecycleBreadcrumb('resumed', 'inactive'), isFalse);
      // 直前が inactive 扱いで記録されていない状態からでも、hidden は通る。
      expect(shouldRecordLifecycleBreadcrumb('resumed', 'hidden'), isTrue);
    });

    test('同じ状態の連続は記録しない', () {
      expect(shouldRecordLifecycleBreadcrumb('resumed', 'resumed'), isFalse);
      expect(shouldRecordLifecycleBreadcrumb('hidden', 'hidden'), isFalse);
    });

    test('⚠ 実在する AppLifecycleState の名前を網羅している', () {
      // `inactive` だけが落ちる側。将来 enum が増えたらここで気づく。
      final recorded = AppLifecycleState.values
          .map((s) => s.name)
          .where((name) => shouldRecordLifecycleBreadcrumb(null, name))
          .toSet();
      expect(recorded, {'resumed', 'hidden', 'paused', 'detached'});
    });
  });
}
