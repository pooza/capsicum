import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1005: Misskey で ALT を空にすると「更新に失敗しました」になり、そもそも
/// 消せなかった。
///
/// ⚠ **Misskey はキーの省略を「変更なし」、明示的な null を「消す」として扱う。**
/// 空文字を null に変換して [MisskeyClient.updateDriveFile] へ渡すと、null-aware
/// element がキーごと省略するため body が `{fileId}` だけになり、Misskey 側は
/// `driveFilesRepository.update` に**空の更新**を渡して 500 で落ちる。
///
/// ここで固定するのは**送信 body の形**。「消す」と「変更なし」が取り違えられて
/// いないことは、これを見ないと分からない（症状は「更新に失敗しました」の 1 行）。
class _CapturingAdapter implements HttpClientAdapter {
  Map<String, dynamic>? lastBody;
  String? lastPath;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    final data = options.data;
    lastBody = data is Map<String, dynamic> ? data : null;
    return ResponseBody.fromString(
      jsonEncode({
        'id': 'file1',
        'name': 'image.png',
        'type': 'image/png',
        'isSensitive': false,
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

void main() {
  group('MisskeyAdapter.updateAttachmentDescription (#1005)', () {
    late MisskeyAdapter adapter;
    late _CapturingAdapter http;

    setUp(() async {
      adapter = await MisskeyAdapter.create('misskey.example');
      http = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = http;
    });

    test('空文字なら comment: null を明示的に送る（消す）', () async {
      await adapter.updateAttachmentDescription('file1', '', postId: 'note1');

      expect(http.lastPath, contains('drive/files/update'));
      expect(
        http.lastBody!.containsKey('comment'),
        isTrue,
        reason: 'キーを省略すると Misskey は「変更なし」と解釈し、ALT を消せない',
      );
      expect(http.lastBody!['comment'], isNull);
    });

    // ⚠ **これが 500 の実体。**更新対象が 1 つも無い body を送ると、Misskey の
    // DriveService.updateFile が空の更新を TypeORM へ渡して落ちる。
    test('空文字でも fileId だけの body にしない', () async {
      await adapter.updateAttachmentDescription('file1', '', postId: 'note1');

      final keys = http.lastBody!.keys.where((k) => k != 'i').toSet();
      expect(keys, {'fileId', 'comment'});
    });

    test('非空ならその文字列を送る', () async {
      await adapter.updateAttachmentDescription(
        'file1',
        '猫の写真',
        postId: 'note1',
      );

      expect(http.lastBody!['comment'], '猫の写真');
    });

    // 変更しないキーまで送らない（省略＝変更なしを利用する側の契約）。
    test('name / folderId は送らない', () async {
      await adapter.updateAttachmentDescription(
        'file1',
        '猫の写真',
        postId: 'note1',
      );

      expect(http.lastBody!.containsKey('name'), isFalse);
      expect(http.lastBody!.containsKey('folderId'), isFalse);
    });
  });
}
