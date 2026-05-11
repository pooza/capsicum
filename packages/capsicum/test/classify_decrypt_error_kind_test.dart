// `classifyDecryptErrorKind` の contract test (#436 v1.25 observation)。
// NSE が記録する error type + case 名から 3 値の二次分類タグを生成する。
import 'package:capsicum/main.dart' show classifyDecryptErrorKind;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyDecryptErrorKind — push.decrypt.kind 二次分類 (#436)', () {
    test('CryptoKitError.authenticationFailure は auth_failure', () {
      expect(
        classifyDecryptErrorKind('CryptoKitError.authenticationFailure'),
        'auth_failure',
      );
    });

    test('WebPushError.invalidKeyId は header', () {
      expect(
        classifyDecryptErrorKind('WebPushError.invalidKeyId'),
        'header',
      );
    });

    test('WebPushError.payloadTruncated は header', () {
      expect(
        classifyDecryptErrorKind('WebPushError.payloadTruncated'),
        'header',
      );
    });

    test('予期しない型名は other', () {
      expect(classifyDecryptErrorKind('SomeOtherError.unknown'), 'other');
      expect(classifyDecryptErrorKind('NSError.()'), 'other');
    });

    test('大文字小文字を問わず判定する (Swift の case 名は小文字始まり)', () {
      expect(
        classifyDecryptErrorKind('cryptokiterror.authenticationFailure'),
        'auth_failure',
      );
    });
  });
}
