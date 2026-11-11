import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/misskey/antenna_mapping.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1052: アンテナの作成・編集・削除。
class _Server implements HttpClientAdapter {
  _Server({this.tooMany = false, this.deleteErrorCode, this.writeErrorCode});

  final bool tooMany;

  /// 削除に返すエラーコード（null なら成功）。
  final String? deleteErrorCode;

  /// 作成・更新に返すエラーコード（null なら成功・#1372）。
  final String? writeErrorCode;
  final requests = <String, Map<String, dynamic>>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests[options.path] = options.data as Map<String, dynamic>;
    if (tooMany && options.path.endsWith('/api/antennas/create')) {
      return _json({
        'error': {'code': 'TOO_MANY_ANTENNAS'},
      }, 400);
    }
    if (writeErrorCode != null &&
        (options.path.endsWith('/api/antennas/create') ||
            options.path.endsWith('/api/antennas/update'))) {
      return _json({
        'error': {'code': writeErrorCode},
      }, 400);
    }
    if (deleteErrorCode != null &&
        options.path.endsWith('/api/antennas/delete')) {
      return _json({
        'error': {'code': deleteErrorCode},
      }, 400);
    }
    return _json(options.path.endsWith('/list') ? [_listed] : {}, 200);
  }

  ResponseBody _json(Object body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

const _listed = {
  'id': 'a1',
  'name': '実況',
  'src': 'users_blacklist',
  'userListId': null,
  'keywords': [
    ['プリキュア', '実況'],
    ['precure'],
  ],
  'excludeKeywords': [
    ['ネタバレ'],
  ],
  'users': ['@spam', '@bot@example.com'],
  'caseSensitive': true,
  'localOnly': false,
  'excludeBots': true,
  'withReplies': true,
  'withFile': false,
  'excludeNotesInSensitiveChannel': true,
};

void main() {
  late MisskeyAdapter adapter;

  Future<_Server> install(_Server server) async {
    adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = server;
    return server;
  }

  test('一覧から条件を全部読む', () async {
    await install(_Server());

    final antenna = (await adapter.getAntennas()).single;
    final c = antenna.conditions!;

    expect(antenna.name, '実況');
    expect(c.source, AntennaSource.usersBlacklist);
    expect(c.keywords, [
      ['プリキュア', '実況'],
      ['precure'],
    ]);
    expect(c.excludeKeywords, [
      ['ネタバレ'],
    ]);
    expect(c.users, ['@spam', '@bot@example.com']);
    expect(c.caseSensitive, isTrue);
    expect(c.excludeBots, isTrue);
    expect(c.withReplies, isTrue);
    expect(c.excludeNotesInSensitiveChannel, isTrue);
  });

  test('欠けた項目は既定で埋める（古い版・フォーク）', () {
    final antenna = misskeyAntennaFromJson({'id': 'x'});

    expect(antenna.conditions!.source, AntennaSource.all);
    expect(antenna.conditions!.keywords, isEmpty);
    expect(antenna.conditions!.withReplies, isFalse);
  });

  test('⚠ 作成では create の必須の項目を全部送る', () async {
    final server = await install(_Server());

    await adapter.createAntenna(
      const AntennaDraft(
        name: '新しい',
        keywords: [
          ['a'],
        ],
      ),
    );

    final sent = server.requests['/api/antennas/create']!;
    expect(
      sent.keys,
      containsAll([
        'name',
        'src',
        'keywords',
        'excludeKeywords',
        'users',
        'caseSensitive',
        'withReplies',
        'withFile',
      ]),
    );
    expect(sent['src'], 'all');
  });

  test('リスト以外では userListId を null で送る（前のリストを残さない）', () {
    final params = misskeyAntennaParams(
      const AntennaDraft(
        name: 'x',
        source: AntennaSource.users,
        userListId: 'old',
      ),
    );

    expect(params['userListId'], isNull);
    expect(params['src'], 'users');
  });

  test('編集は antennaId を添えて送る', () async {
    final server = await install(_Server());

    await adapter.updateAntenna('a1', const AntennaDraft(name: '変えた'));

    final sent = server.requests['/api/antennas/update']!;
    expect(sent['antennaId'], 'a1');
    expect(sent['name'], '変えた');
  });

  test('削除は antennaId を送る', () async {
    final server = await install(_Server());

    await adapter.deleteAntenna('a1');

    expect(server.requests['/api/antennas/delete']!['antennaId'], 'a1');
  });

  test('⚠ 既に消えていた（NO_SUCH_ANTENNA）なら、削除は成功として扱う', () async {
    await install(_Server(deleteErrorCode: 'NO_SUCH_ANTENNA'));

    await adapter.deleteAntenna('a1');
  });

  test('ほかの失敗は、そのまま投げる', () async {
    await install(_Server(deleteErrorCode: 'PERMISSION_DENIED'));

    await expectLater(
      adapter.deleteAntenna('a1'),
      throwsA(isA<DioException>()),
    );
  });

  test('ロールの上限（TOO_MANY_ANTENNAS）は AntennaLimitReached にする', () async {
    await install(_Server(tooMany: true));

    await expectLater(
      adapter.createAntenna(const AntennaDraft(name: 'x')),
      throwsA(isA<AntennaLimitReached>()),
    );
  });

  group('#1372: 既に消えたものは型に写す（画面が Sentry へ送らないため）', () {
    test('更新先のアンテナが無い（NO_SUCH_ANTENNA）は AntennaNotFound', () async {
      await install(_Server(writeErrorCode: 'NO_SUCH_ANTENNA'));

      await expectLater(
        adapter.updateAntenna('a1', const AntennaDraft(name: 'x')),
        throwsA(isA<AntennaNotFound>()),
      );
    });

    test('受信元のリストが無い（NO_SUCH_USER_LIST）は作成でも更新でも '
        'AntennaUserListNotFound', () async {
      await install(_Server(writeErrorCode: 'NO_SUCH_USER_LIST'));

      await expectLater(
        adapter.createAntenna(const AntennaDraft(name: 'x')),
        throwsA(isA<AntennaUserListNotFound>()),
      );
      await expectLater(
        adapter.updateAntenna('a1', const AntennaDraft(name: 'x')),
        throwsA(isA<AntennaUserListNotFound>()),
      );
    });

    test('⚠ ほかのエラーはそのまま投げる（握りつぶさない）', () async {
      await install(_Server(writeErrorCode: 'EMPTY_KEYWORD'));

      await expectLater(
        adapter.updateAntenna('a1', const AntennaDraft(name: 'x')),
        throwsA(isA<DioException>()),
      );
    });
  });
}
