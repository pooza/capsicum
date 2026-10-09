import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1205: Misskey の通知の既読を返す口。
///
/// ⚠⚠ **隣に全消しの API がある。**`notifications/flush` は既読ではなく削除で、
/// 取り違えると利用者の通知が全部消える。叩いたパスを固定する。
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
      jsonEncode(options.path.contains('i/notifications') ? <Object>[] : null),
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
  test('全既読は notifications/mark-all-as-read を叩く（flush ではない）', () async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    final recorder = _Recorder();
    adapter.client.dio.httpClientAdapter = recorder;

    await adapter.markAllNotificationsRead();

    final request = recorder.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/notifications/mark-all-as-read');
  });

  test('⚠⚠ 取得では既読にしない（markAsRead: false を送り続ける・#1045）', () async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    final recorder = _Recorder();
    adapter.client.dio.httpClientAdapter = recorder;

    await adapter.getNotifications();

    final body = recorder.requests.single.data as Map<String, dynamic>;
    expect(body['markAsRead'], isFalse, reason: '既読を返す口を足しても、取得で消す側へ戻さない');
    expect(
      recorder.requests.map((r) => r.path),
      isNot(contains('/api/notifications/mark-all-as-read')),
    );
  });

  test('Mastodon は全既読の口を持たない（位置で返す MarkerSupport の側）', () async {
    final DecentralizedBackendAdapter adapter = await MastodonAdapter.create(
      'example.com',
    );
    expect(adapter, isNot(isA<NotificationReadSupport>()));
    expect(adapter, isA<MarkerSupport>());
  });
}
