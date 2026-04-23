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

    test('Misskey 形式 (notification / mention) から type と note.text を取り出す', () {
      final plaintext = _utf8(
        jsonEncode({
          'type': 'notification',
          'body': {
            'id': 'abcd',
            'type': 'mention',
            'user': {'name': 'Alice', 'username': 'alice'},
            'note': {'id': 'note1', 'text': 'こんにちは'},
          },
          'userId': 'u1',
          'dateTime': 1700000000000,
        }),
      );
      final result = PushMessageDispatcher.parsePayload(plaintext);
      expect(result, isNotNull);
      expect(result!.type, 'mention');
      expect(result.body, 'こんにちは');
    });

    test('Misskey 形式 (reaction / note.text 無し) は送信者+リアクションを合成', () {
      final plaintext = _utf8(
        jsonEncode({
          'type': 'notification',
          'body': {
            'type': 'reaction',
            'user': {'name': 'Bob', 'username': 'bob'},
            'reaction': ':thumbsup:',
          },
        }),
      );
      final result = PushMessageDispatcher.parsePayload(plaintext);
      expect(result, isNotNull);
      expect(result!.type, 'reaction');
      expect(result.body, 'Bob が :thumbsup: でリアクション');
    });

    test('Misskey 形式 (follow) は「@user にフォローされました」を合成', () {
      final plaintext = _utf8(
        jsonEncode({
          'type': 'notification',
          'body': {
            'type': 'follow',
            'user': {'name': '', 'username': 'charlie'},
          },
        }),
      );
      final result = PushMessageDispatcher.parsePayload(plaintext);
      expect(result, isNotNull);
      expect(result!.type, 'follow');
      expect(result.body, '@charlie にフォローされました');
    });

    test('Misskey 形式 (renote) は元投稿の note.text を使う', () {
      final plaintext = _utf8(
        jsonEncode({
          'type': 'notification',
          'body': {
            'type': 'renote',
            'user': {'name': 'Dave', 'username': 'dave'},
            'note': {'text': 'リノート元の本文'},
          },
        }),
      );
      final result = PushMessageDispatcher.parsePayload(plaintext);
      expect(result, isNotNull);
      expect(result!.type, 'renote');
      expect(result.body, 'リノート元の本文');
    });

    test('Misskey の readAllNotifications は通知表示対象外で null', () {
      final plaintext = _utf8(jsonEncode({'type': 'readAllNotifications'}));
      expect(PushMessageDispatcher.parsePayload(plaintext), isNull);
    });
  });
}
