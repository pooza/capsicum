import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #865: profile 編集の locked（承認制）/ discoverable（ディレクトリ掲載）。
///
/// - client がリクエストボディに正しいキー・値を載せること
///   （Mastodon `locked`/`discoverable`・Misskey `isLocked`/`isExplorable`）
/// - サーバー応答（account / user）から User.locked/discoverable へ mapping すること
/// を検証する。null（未指定）はキーを送らないことも確認する。

/// 送信ボディを丸ごと文字列で捕捉し、固定応答を返すアダプタ。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.responseBody);

  final Object responseBody;
  String? capturedBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      final chunks = <int>[];
      await for (final c in requestStream) {
        chunks.addAll(c);
      }
      capturedBody = utf8.decode(chunks, allowMalformed: true);
    }
    return ResponseBody.fromString(
      responseBody is String
          ? responseBody as String
          : jsonEncode(responseBody),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _mastodonAccount({bool? locked, bool? discoverable}) => {
  'id': '1',
  'username': 'capsicum',
  'acct': 'capsicum',
  'display_name': 'capsicum',
  'note': '',
  'avatar': '',
  'header': '',
  'followers_count': 0,
  'following_count': 0,
  'statuses_count': 0,
  'fields': <Map<String, dynamic>>[],
  'locked': ?locked,
  'discoverable': ?discoverable,
};

Map<String, dynamic> _misskeyUser({bool? isLocked, bool? isExplorable}) => {
  'id': 'u1',
  'username': 'capsicum',
  'isLocked': ?isLocked,
  'isExplorable': ?isExplorable,
};

void main() {
  group('Mastodon updateProfile — locked / discoverable', () {
    test('locked=true / discoverable=false をボディに載せる', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final capture = _CapturingAdapter(_mastodonAccount());
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.updateProfile(locked: true, discoverable: false);

      final body = capture.capturedBody ?? '';
      expect(
        RegExp('name="locked"\r\n\r\ntrue').hasMatch(body),
        isTrue,
        reason: 'locked=true が multipart に載るべき: $body',
      );
      expect(
        RegExp('name="discoverable"\r\n\r\nfalse').hasMatch(body),
        isTrue,
        reason: 'discoverable=false が multipart に載るべき',
      );
    });

    test('null（未指定）はキーを送らない', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final capture = _CapturingAdapter(_mastodonAccount());
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.updateProfile(displayName: 'x');

      final body = capture.capturedBody ?? '';
      expect(body.contains('name="locked"'), isFalse);
      expect(body.contains('name="discoverable"'), isFalse);
    });

    test('応答の locked / discoverable を User に写す', () {
      final user = MastodonAccount.fromJson(
        _mastodonAccount(locked: true, discoverable: false),
      ).toCapsicum('example.com');
      expect(user.locked, isTrue);
      expect(user.discoverable, isFalse);
    });
  });

  group('Misskey updateProfile — isLocked / isExplorable', () {
    test('locked/discoverable を isLocked/isExplorable としてボディに載せる', () async {
      final adapter = await MisskeyAdapter.create('example.com');
      final capture = _CapturingAdapter(_misskeyUser());
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.updateProfile(locked: true, discoverable: false);

      final body = jsonDecode(capture.capturedBody ?? '{}') as Map;
      expect(body['isLocked'], isTrue);
      expect(body['isExplorable'], isFalse);
    });

    test('null（未指定）はキーを送らない', () async {
      final adapter = await MisskeyAdapter.create('example.com');
      final capture = _CapturingAdapter(_misskeyUser());
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.updateProfile(displayName: 'x');

      final body = jsonDecode(capture.capturedBody ?? '{}') as Map;
      expect(body.containsKey('isLocked'), isFalse);
      expect(body.containsKey('isExplorable'), isFalse);
    });

    test('応答の isLocked / isExplorable を User に写す', () {
      final user = MisskeyUser.fromJson(
        _misskeyUser(isLocked: true, isExplorable: false),
      ).toCapsicum('example.com');
      expect(user.locked, isTrue);
      expect(user.discoverable, isFalse);
    });
  });
}
