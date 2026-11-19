import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1287: `/api/v2/instance` が無いサーバー（Akkoma などの Pleroma 系）では、
/// 投稿の上限を `/api/v1/instance` から読む。
///
/// ⚠ Akkoma 3.20 は v2 が 404 で、上限は v1 の `max_toot_chars`（既定 5000）に
/// だけ出る。以前は v2 しか読まず、モロヘイヤの無い Akkoma でカウンタが
/// `/500` になっていた。
class _Adapter implements HttpClientAdapter {
  _Adapter({this.v2, this.v1});

  /// null なら 404 を返す。
  final Map<String, dynamic>? v2;
  final Map<String, dynamic>? v1;

  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.path);
    Map<String, dynamic>? body;
    if (options.path.contains('/api/v2/instance')) {
      body = v2;
    } else if (options.path.contains('/api/v1/instance')) {
      body = v1;
    } else {
      body = <String, dynamic>{};
    }
    if (body == null) {
      return ResponseBody.fromString(
        '{"error":"Not found"}',
        404,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
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
  Future<(MastodonAdapter, _Adapter)> detectWith(_Adapter http) async {
    final adapter = await MastodonAdapter.create('akkoma.example');
    adapter.client.dio.httpClientAdapter = http;
    await adapter.detectTimelineAvailability();
    return (adapter, http);
  }

  test('v2 が無ければ v1 の max_toot_chars を上限にする（Akkoma）', () async {
    final (adapter, _) = await detectWith(
      _Adapter(v1: {'max_toot_chars': 5000}),
    );

    expect(adapter.capabilities.maxPostContentLength, 5000);
  });

  test('v1 に configuration.statuses.max_characters があればそちらを先に見る', () async {
    final (adapter, _) = await detectWith(
      _Adapter(
        v1: {
          'configuration': {
            'statuses': {'max_characters': 3000},
          },
          'max_toot_chars': 5000,
        },
      ),
    );

    expect(adapter.capabilities.maxPostContentLength, 3000);
  });

  test('v1 も読めなければ 500 のまま', () async {
    final (adapter, _) = await detectWith(_Adapter());

    expect(adapter.capabilities.maxPostContentLength, 500);
  });

  test('⚠ v1 の値が数値でなければ上書きしない', () async {
    final (adapter, _) = await detectWith(
      _Adapter(v1: {'max_toot_chars': '5000'}),
    );

    expect(adapter.capabilities.maxPostContentLength, 500);
  });

  // #1396: v2 が 200 でも上限を欠くサーバーでは、既定の 500 に落ちていた。
  test('v2 が 200 でも上限を欠いていれば v1 を見る', () async {
    final (adapter, http) = await detectWith(
      _Adapter(
        v2: {
          'configuration': {'timelines_access': <String, dynamic>{}},
        },
        v1: {'max_toot_chars': 5000},
      ),
    );

    expect(adapter.capabilities.maxPostContentLength, 5000);
    expect(
      http.requested.where((p) => p.contains('/api/v1/instance')),
      isNotEmpty,
    );
  });

  test('v2 の上限が数値でなければ v1 を見る', () async {
    final (adapter, _) = await detectWith(
      _Adapter(
        v2: {
          'configuration': {
            'statuses': {'max_characters': '3000'},
            'timelines_access': <String, dynamic>{},
          },
        },
        v1: {'max_toot_chars': 5000},
      ),
    );

    expect(adapter.capabilities.maxPostContentLength, 5000);
  });

  test('⚠ v2 が読めたときは v1 を引かない（本家 Mastodon の経路は変えない）', () async {
    final (adapter, http) = await detectWith(
      _Adapter(
        v2: {
          'configuration': {
            'statuses': {'max_characters': 3000},
            'timelines_access': <String, dynamic>{},
          },
        },
        v1: {'max_toot_chars': 9999},
      ),
    );

    expect(adapter.capabilities.maxPostContentLength, 3000);
    expect(
      http.requested.where((p) => p.contains('/api/v1/instance')),
      isEmpty,
    );
  });
}
