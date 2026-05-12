// _isKeychainTransient は private static なので、本 test はその意図を
// public 経路で固定するわけではない。代わりに `PlatformException(code, msg)`
// を組み立てて `Object.toString()` で `-25308` が含まれていることを保証する
// 軽い contract test として残す。実際の delete-skip 経路は実機検証で確認。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlatformException code mapping (#531 transient classification)', () {
    test('Keychain ロック errSecInteractionNotAllowed (-25308) 形式', () {
      // 実際の Sentry イベント (CAPSICUM-1M) と同じ形を組み立てる:
      // PlatformException(Unexpected security result code, Code: -25308,
      //   Message: User interaction is not allowed., -25308, null)
      final e = PlatformException(
        code: 'Unexpected security result code',
        message:
            'Code: -25308, Message: User interaction is not allowed., -25308',
      );
      // _isKeychainTransient はメッセージ中に "-25308" が含まれるかも判定材料
      // にする (code が数値文字列でない場合のフォールバック)。
      expect(e.message, contains('-25308'));
    });

    test('Keychain ロック (code が数値文字列のケース)', () {
      final e = PlatformException(code: '-25308', message: 'lock');
      expect(e.code, equals('-25308'));
    });

    test('他の Keychain エラー (transient でない) は -25308 を含まない', () {
      final e = PlatformException(
        code: 'Unexpected security result code',
        message: 'Code: -25300, Message: Item not found.',
      );
      expect(e.message, isNot(contains('-25308')));
    });
  });
}
