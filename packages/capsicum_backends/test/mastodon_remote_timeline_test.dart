import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/mastodon/streaming.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1278: リモートのみの連合 TL（`/api/v1/timelines/public?remote=true`）。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.instance);

  final Map<String, dynamic> instance;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final Object body = options.path.contains('/api/v2/instance')
        ? instance
        : <Object>[];
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

Map<String, dynamic> _instance(String remote) => {
  'configuration': {
    'timelines_access': {
      'live_feeds': {'local': 'public', 'remote': remote},
    },
  },
};

void main() {
  test('remote=true を付けて引く', () async {
    final adapter = await MastodonAdapter.create('mastodon.example');
    final http = _Recorder(_instance('public'));
    adapter.client.dio.httpClientAdapter = http;

    await adapter.getTimeline(TimelineType.remote);

    final request = http.requests.single;
    expect(request.path, '/api/v1/timelines/public');
    expect(request.queryParameters['remote'], isTrue);
    expect(request.queryParameters.containsKey('local'), isFalse);
  });

  test('連合 TL は remote を付けない（従来どおり）', () async {
    final adapter = await MastodonAdapter.create('mastodon.example');
    final http = _Recorder(_instance('public'));
    adapter.client.dio.httpClientAdapter = http;

    await adapter.getTimeline(TimelineType.federated);

    expect(http.requests.single.queryParameters.containsKey('remote'), isFalse);
  });

  test('⚠ 出すかは連合と同じ設定（live_feeds.remote）に従う', () async {
    final open = await MastodonAdapter.create('mastodon.example');
    open.client.dio.httpClientAdapter = _Recorder(_instance('public'));
    await open.detectTimelineAvailability();
    expect(open.capabilities.supportedTimelines, contains(TimelineType.remote));

    final closed = await MastodonAdapter.create('mastodon.example');
    closed.client.dio.httpClientAdapter = _Recorder(_instance('disabled'));
    await closed.detectTimelineAvailability();
    expect(
      closed.capabilities.supportedTimelines,
      isNot(contains(TimelineType.remote)),
    );
    expect(
      closed.capabilities.supportedTimelines,
      isNot(contains(TimelineType.federated)),
    );
  });

  test('ライブ更新は public:remote のストリーム', () {
    expect(
      mastodonStreamTarget(const TimelineTab(TimelineType.remote))?.stream,
      'public:remote',
    );
  });

  test('Misskey には出さない', () async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    expect(
      adapter.capabilities.supportedTimelines,
      isNot(contains(TimelineType.remote)),
    );
  });
}
