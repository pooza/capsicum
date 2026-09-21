import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1144: Mastodon の投稿の上限を、サーバーの
/// `configuration.statuses.max_characters` から取る。
///
/// ⚠ 以前は 500 の決め打ちで、`MAX_CHARS` を変えたサーバー（pooza のフォークは
/// 3000）でもカウンタが `/500` だった（モロヘイヤが上限を返すサーバーは除く）。
class _InstanceAdapter implements HttpClientAdapter {
  _InstanceAdapter(this.instance);

  final Map<String, dynamic> instance;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = options.path.contains('/api/v2/instance')
        ? instance
        : <String, dynamic>{};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  Future<MastodonAdapter> detectWith(Map<String, dynamic> instance) async {
    final adapter = await MastodonAdapter.create('mastodon.example');
    adapter.client.dio.httpClientAdapter = _InstanceAdapter(instance);
    await adapter.detectTimelineAvailability();
    return adapter;
  }

  test('サーバーの max_characters を上限にする', () async {
    final adapter = await detectWith({
      'configuration': {
        'statuses': {'max_characters': 3000},
        'timelines_access': <String, dynamic>{},
      },
    });

    expect(adapter.capabilities.maxPostContentLength, 3000);
  });

  test('値が無ければ 500 のまま（4.x 以前・取得失敗）', () async {
    final adapter = await detectWith({'configuration': <String, dynamic>{}});

    expect(adapter.capabilities.maxPostContentLength, 500);
  });

  test('⚠ 0 以下や数値でない値では上書きしない', () async {
    final zero = await detectWith({
      'configuration': {
        'statuses': {'max_characters': 0},
      },
    });
    expect(zero.capabilities.maxPostContentLength, 500);

    final text = await detectWith({
      'configuration': {
        'statuses': {'max_characters': '3000'},
      },
    });
    expect(text.capabilities.maxPostContentLength, 500);
  });
}
