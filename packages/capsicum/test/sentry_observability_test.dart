import 'package:capsicum/src/util/sentry_observability.dart';
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
}
