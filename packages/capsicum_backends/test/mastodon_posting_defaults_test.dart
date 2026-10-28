import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1210: サーバー側の投稿の既定（`source[*]`）と、アイコン・ヘッダーの ALT を
/// capsicum から書く。
class _Recorder implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'id': '1',
        'username': 'me',
        'acct': 'me',
        'display_name': '',
        'note': '',
        'avatar': '',
        'header': '',
        'followers_count': 0,
        'following_count': 0,
        'statuses_count': 0,
        'fields': <Object>[],
        'source': {'privacy': 'unlisted', 'sensitive': true, 'language': 'ja'},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, String> _fields(RequestOptions options) => {
  for (final field in (options.data as FormData).fields) field.key: field.value,
};

void main() {
  late MastodonAdapter adapter;
  late _Recorder http;

  setUp(() async {
    adapter = await MastodonAdapter.create('mastodon.example');
    http = _Recorder();
    adapter.client.dio.httpClientAdapter = http;
  });

  test('投稿の既定を source[...] で送る', () async {
    final user = await adapter.updatePostingDefaults(
      scope: PostScope.followersOnly,
      sensitive: true,
      language: 'ja',
      quotePolicy: 'followers',
    );

    final request = http.requests.single;
    expect(request.method, 'PATCH');
    expect(request.path, '/api/v1/accounts/update_credentials');
    expect(_fields(request), {
      'source[privacy]': 'private',
      'source[sensitive]': 'true',
      'source[language]': 'ja',
      'source[quote_policy]': 'followers',
    });
    expect(user.defaultScope, PostScope.unlisted, reason: '応答の値で返す');
  });

  test('⚠ null の項目は送らない（上流は送らなかった項目を今の値のまま残す）', () async {
    await adapter.updatePostingDefaults(sensitive: false);

    expect(_fields(http.requests.single), {'source[sensitive]': 'false'});
  });

  test('CW 欄の既定を source[spoiler_field] で送る (#1322)', () async {
    await adapter.updatePostingDefaults(spoilerField: true);

    expect(_fields(http.requests.single), {'source[spoiler_field]': 'true'});
  });

  test('言語の「指定しない」は空文字で送る', () async {
    await adapter.updatePostingDefaults(language: '');

    expect(_fields(http.requests.single), {'source[language]': ''});
  });

  test('アイコン・ヘッダーの ALT を送る（null は送らない）', () async {
    await adapter.updateProfile(avatarDescription: 'ダイの絵');

    final fields = _fields(http.requests.single);
    expect(fields['avatar_description'], 'ダイの絵');
    expect(fields.containsKey('header_description'), isFalse);
  });

  test('ALT の空文字は「消す」として送る', () async {
    await adapter.updateProfile(headerDescription: '');

    expect(_fields(http.requests.single)['header_description'], '');
  });
}
