import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1236: 除外する種別をサーバーが知らないとき（古い Misskey）に、通知が出なく
/// なったり、グループ化が巻き添えで無効になったりしない。
///
/// ⚠⚠ `excludeTypes` は enum で検証されるので、その種別を持たないサーバーは
/// **400** を返す。以前はグループ化の経路がこれを「エンドポイントが無い」と読んで
/// 非対応のフラグを立て、同じ `excludeTypes` で非グループを試してまた 400 に
/// なっていた。除外を外してもグループ化は戻らなかった。
///
/// ここでは「`excludeTypes` が載っていたら 400 を返すサーバー」を立て、実際に
/// 飛んだリクエストの並びを見る。
class _RejectsExclude implements HttpClientAdapter {
  _RejectsExclude({this.notifications = const [], this.hasGrouped = true});

  /// 除外なしのリクエストに返す通知。
  final List<Map<String, dynamic>> notifications;

  /// `i/notifications-grouped` を持つサーバーか。持たなければ 404。
  final bool hasGrouped;

  /// 飛んだリクエストを「経路 + 除外の有無」で記録する。
  final List<String> log = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final grouped = options.path.endsWith('notifications-grouped');
    final body = options.data as Map<String, dynamic>;
    final hasExclude = body.containsKey('excludeTypes');
    log.add('${grouped ? 'grouped' : 'plain'}${hasExclude ? '+exclude' : ''}');
    final int status;
    if (grouped && !hasGrouped) {
      status = 404;
    } else if (hasExclude) {
      status = 400;
    } else {
      status = 200;
    }
    return ResponseBody.fromString(
      status == 200 ? jsonEncode(notifications) : '{"error":{}}',
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  Map<String, dynamic> notification(String id, String type) => {
    'id': id,
    'createdAt': '2026-10-08T00:00:00.000Z',
    'type': type,
    'user': {'id': 'u1', 'username': 'alice', 'name': 'Alice'},
  };

  Future<(MisskeyAdapter, _RejectsExclude)> setUpServer({
    List<Map<String, dynamic>> notifications = const [],
    bool hasGrouped = true,
  }) async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    final server = _RejectsExclude(
      notifications: notifications,
      hasGrouped: hasGrouped,
    );
    adapter.client.dio.httpClientAdapter = server;
    return (adapter, server);
  }

  const excludeFollow = NotificationQuery(
    grouped: true,
    excludeTypes: {NotificationType.follow},
  );

  test('⚠⚠ 除外で 400 になっても、グループ化は保ったまま除外なしで取り直す', () async {
    final (adapter, server) = await setUpServer();

    await adapter.getNotifications(filter: excludeFollow);
    expect(server.log, ['grouped+exclude', 'grouped']);

    // 🔴 以前はここで非対応のフラグが立ち、除外を外してもグループ化が戻らなかった。
    server.log.clear();
    await adapter.getNotifications(
      filter: const NotificationQuery(grouped: true),
    );
    expect(server.log, ['grouped'], reason: 'グループ化は無効になっていない');
  });

  test('⚠⚠ 非グループでも、除外で 400 なら除外なしで取り直す（通知が出る）', () async {
    final (adapter, server) = await setUpServer(
      notifications: [notification('n1', 'reaction')],
    );

    final response = await adapter.getNotifications(
      filter: const NotificationQuery(excludeTypes: {NotificationType.follow}),
    );

    expect(server.log, ['plain+exclude', 'plain']);
    expect(response.notifications, hasLength(1), reason: '🔴 以前は例外で一覧が空');
  });

  test('⚠ 除外を送れなかった回は、外した種別を手元で落とす', () async {
    final (adapter, _) = await setUpServer(
      notifications: [
        notification('n3', 'follow'),
        notification('n2', 'reaction'),
        notification('n1', 'follow'),
      ],
    );

    final response = await adapter.getNotifications(filter: excludeFollow);

    expect(response.notifications.map((n) => n.id), ['n2']);
    // ⚠ カーソルは落とす前の末尾（ページングをずらさない）。
    expect(response.rawLastId, 'n1');
    expect(response.rawCount, 3);
  });

  test('断られた組は覚えておき、次のページでは最初から送らない', () async {
    final (adapter, server) = await setUpServer();

    await adapter.getNotifications(filter: excludeFollow);
    server.log.clear();
    await adapter.getNotifications(filter: excludeFollow);

    expect(server.log, ['grouped'], reason: 'ページごとに 400 を踏み直さない');
  });

  test('⚠ 組が変わったら、あらためてサーバーへ送る', () async {
    final (adapter, server) = await setUpServer();

    await adapter.getNotifications(filter: excludeFollow);
    server.log.clear();
    await adapter.getNotifications(
      filter: const NotificationQuery(
        grouped: true,
        excludeTypes: {NotificationType.mention},
      ),
    );

    expect(server.log.first, 'grouped+exclude', reason: '通る組かもしれない');
  });

  test('グループ化のエンドポイントが無いサーバーでは、従来どおり非グループへ落とす', () async {
    final (adapter, server) = await setUpServer(hasGrouped: false);

    await adapter.getNotifications(
      filter: const NotificationQuery(grouped: true),
    );
    expect(server.log, ['grouped', 'plain']);

    server.log.clear();
    await adapter.getNotifications(
      filter: const NotificationQuery(grouped: true),
    );
    expect(server.log, ['plain'], reason: '無いと分かったら叩かない');
  });
}
