import 'dart:convert';
import 'dart:typed_data';

import 'package:capsicum/src/service/push_message_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('PushMessageDispatcher.parsePayload', () {
    test('Mastodon 形式 (title + body + notification_type) を取り出す', () {
      final plaintext = _utf8(
        jsonEncode({
          'title': '@alice さんから返信がありました',
          'body': 'こんにちは',
          'notification_id': 12345,
          'notification_type': 'mention',
        }),
      );

      final result = PushMessageDispatcher.parsePayload(plaintext);

      expect(result, isNotNull);
      expect(result!.title, '@alice さんから返信がありました');
      expect(result.body, 'こんにちは');
      expect(result.type, 'mention');
    });

    test('title だけでも取り出せる', () {
      final plaintext = _utf8(jsonEncode({'title': 'ブーストされました'}));
      final result = PushMessageDispatcher.parsePayload(plaintext);
      expect(result, isNotNull);
      expect(result!.title, 'ブーストされました');
      expect(result.body, isNull);
    });

    test('title / body が無い JSON は null', () {
      final plaintext = _utf8(
        jsonEncode({'type': 'notification', 'foo': 'bar'}),
      );
      expect(PushMessageDispatcher.parsePayload(plaintext), isNull);
    });

    test('不正な JSON は null', () {
      final plaintext = _utf8('not a json');
      expect(PushMessageDispatcher.parsePayload(plaintext), isNull);
    });

    test('JSON ではあるが Map でない (配列) は null', () {
      final plaintext = _utf8(jsonEncode(['a', 'b']));
      expect(PushMessageDispatcher.parsePayload(plaintext), isNull);
    });
  });
}
