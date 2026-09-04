import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1041 の回帰テスト。
///
/// ⚠⚠ **守りたいのは「0 件」と「引けない」を混ぜないこと。**Misskey は全文検索
/// バックエンド（Meilisearch / pgroonga 等）を別立てで持つ構成で、未設定の
/// サーバーは `notes/search` に `UNAVAILABLE` を返す。プリセットのダイスキー・
/// きゅあすきーとも未設定（2026-09-04 実測）。空リストとして扱うと
/// 「その語の投稿は無い」に見え、実際より悪い誤解を与える。
///
/// ⚠ **host で分岐しない。**検出して出し分ける（probing ベースの基本戦略）。
///
/// ⚠ **実サーバーには出さない。**`MisskeyClient.dio` は public なので、
/// `httpClientAdapter` を差し替えて**本物の [MisskeyClient.searchNotes] を
/// 呼ぶ**。判定を写経すると、本体を直したときにテストだけ古くなる。
void main() {
  late MisskeyClient client;
  late _StubAdapter stub;

  setUp(() {
    client = MisskeyClient('example.test');
    stub = _StubAdapter();
    client.dio.httpClientAdapter = stub;
  });

  group('MisskeyClient.searchNotes (#1041)', () {
    test('UNAVAILABLE は null（＝このサーバーでは引けない）を返す', () async {
      stub.respondWith(
        statusCode: 400,
        body: {
          'error': {
            'message': 'Search of notes unavailable.',
            'code': 'UNAVAILABLE',
            'id': '0b44998d-77aa-4427-80d0-d2c9b8523011',
            'kind': 'client',
          },
        },
      );

      expect(
        await client.searchNotes('capsicum'),
        isNull,
        reason: 'UNAVAILABLE を空リストに潰すと「0 件」と区別できなくなる',
      );
    });

    test('UNAVAILABLE 以外のエラーは握りつぶさない', () async {
      // 本当の障害まで「本文検索に対応していません」と出すと誤診を招く。
      stub.respondWith(
        statusCode: 500,
        body: {
          'error': {'code': 'INTERNAL_ERROR'},
        },
      );

      expect(
        () => client.searchNotes('capsicum'),
        throwsA(isA<DioException>()),
      );
    });

    test('成功時は投稿のリストを返す', () async {
      stub.respondWith(
        statusCode: 200,
        body: [
          {
            'id': 'note1',
            'createdAt': '2026-09-04T00:00:00.000Z',
            'text': 'capsicum のテスト',
            'userId': 'u1',
            'user': {'id': 'u1', 'username': 'someone'},
            'visibility': 'public',
            'renoteCount': 0,
            'repliesCount': 0,
          },
        ],
      );

      final notes = await client.searchNotes('capsicum');
      expect(notes, hasLength(1));
      expect(notes!.single.id, 'note1');
    });
  });
}

/// 固定の応答を返すだけの [HttpClientAdapter]。
class _StubAdapter implements HttpClientAdapter {
  late int _statusCode;
  late Object _body;

  void respondWith({required int statusCode, required Object body}) {
    _statusCode = statusCode;
    _body = body;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(_body),
    _statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
