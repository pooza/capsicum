import 'package:capsicum/src/util/upstream_error_message.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 上流（モロヘイヤ経由）のエラーレスポンスを模した DioException を作る。
DioException _dioError(Object? body, {int status = 400}) {
  final options = RequestOptions(path: '/api/notes/drafts/create');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<Object?>(
      requestOptions: options,
      statusCode: status,
      data: body,
    ),
  );
}

void main() {
  group('Misskey 形（error がオブジェクト）', () {
    test('既知の code は日本語の理由に訳す（#879 の下書き上限）', () {
      // mulukhiya#4480 の透過後に実際に届く形。
      final error = _dioError({
        'error': {
          'code': 'TOO_MANY_DRAFTS',
          'message': 'You cannot create drafts any more.',
          'id': '9ee33bbe-fde3-4c71-9b51-e50492c6b9c8',
          'kind': 'client',
        },
      });
      expect(upstreamErrorMessage(error), '下書きの数が上限に達しています。不要な下書きを削除してください');
      expect(
        upstreamFailureText('下書きの保存に失敗しました', error),
        '下書きの保存に失敗しました: 下書きの数が上限に達しています。不要な下書きを削除してください',
      );
    });

    test('上限値の数字を文面に埋め込まない（noteDraftLimit はロールポリシー）', () {
      // 既定は 10 だがロールで変わる。「10 件までです」と書くと上限を上げた
      // サーバーで嘘になるため、数字を持たないことをテストで固定する。
      final reason = misskeyErrorReason('TOO_MANY_DRAFTS')!;
      expect(RegExp(r'\d').hasMatch(reason), isFalse);
      expect(
        RegExp(r'\d').hasMatch(misskeyErrorReason('TOO_MANY_SCHEDULED_NOTES')!),
        isFalse,
      );
    });

    test('未知の code は英語 message へ倒さず null（汎用文言を使わせる）', () {
      final error = _dioError({
        'error': {
          'code': 'SOME_BRAND_NEW_CODE',
          'message': 'Some files are not found.',
          'id': 'x',
        },
      });
      expect(upstreamErrorMessage(error), isNull);
      expect(upstreamFailureText('下書きの保存に失敗しました', error), '下書きの保存に失敗しました');
    });

    test('code が無い / 文字列でないオブジェクトは null', () {
      expect(
        upstreamErrorMessage(
          _dioError({
            'error': {'message': 'no code here'},
          }),
        ),
        isNull,
      );
      expect(
        upstreamErrorMessage(
          _dioError({
            'error': {'code': 42},
          }),
        ),
        isNull,
      );
    });
  });

  group('Mastodon 形（error が文字列）', () {
    test('人間向けの散文はそのまま出す', () {
      final error = _dioError({'error': 'Validation failed: Text is too long'});
      expect(
        upstreamErrorMessage(error),
        'Validation failed: Text is too long',
      );
    });

    test('モロヘイヤ自身が返す 413 の日本語文言も通す', () {
      final error = _dioError({
        'error': 'アップロードしたファイルがサーバーの上限サイズを超過しています。',
      }, status: 413);
      expect(upstreamErrorMessage(error), 'アップロードしたファイルがサーバーの上限サイズを超過しています。');
    });

    test('透過できなかった残骸 `Bad response NNN` は出さない', () {
      // 上流が JSON を返さない（nginx の HTML 502 等）/ ボディが 64KiB 超の
      // ときに来る。ユーザーには意味がないので汎用文言に倒す。
      for (final body in ['Bad response 400', 'Bad response 502']) {
        final error = _dioError({'error': body});
        expect(upstreamErrorMessage(error), isNull, reason: body);
      }
      // 前後に文脈がある文はフラット化の残骸ではないので通す。
      expect(
        upstreamErrorMessage(_dioError({'error': 'Bad response 400 from foo'})),
        'Bad response 400 from foo',
      );
    });

    test('空 / 複数行 / 長すぎる文字列は出さない', () {
      expect(upstreamErrorMessage(_dioError({'error': '   '})), isNull);
      expect(upstreamErrorMessage(_dioError({'error': 'a\nb'})), isNull);
      expect(upstreamErrorMessage(_dioError({'error': 'あ' * 201})), isNull);
      expect(
        upstreamErrorMessage(_dioError({'error': 'あ' * 200}))?.length,
        200,
      );
    });
  });

  group('理由を解決できない入力', () {
    test('404 は透過が効かず Ginseng の形になる（error キーが無い）', () {
      // mulukhiya#4520: Sinatra の not_found ハンドラがボディを差し替える。
      final error = _dioError({
        'package': 'ginseng-core',
        'class': 'Ginseng::NotFoundError',
        'message': 'Not Found',
      }, status: 404);
      expect(upstreamErrorMessage(error), isNull);
    });

    test('DioException でない例外・ボディが Map でない場合は null', () {
      expect(upstreamErrorMessage(StateError('boom')), isNull);
      expect(upstreamErrorMessage(_dioError('<html>502</html>')), isNull);
      expect(upstreamErrorMessage(_dioError(null)), isNull);
    });

    test('レスポンスを持たない DioException（接続断など）は null', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/api/notes/create'),
        type: DioExceptionType.connectionError,
      );
      expect(upstreamErrorMessage(error), isNull);
      expect(upstreamFailureText('投稿に失敗しました', error), '投稿に失敗しました');
    });
  });

  test('収録コードはすべて非空の理由を返す', () {
    // 表の typo（値が空・キーの重複でつぶれる）を機械的に弾く。
    for (final code in const [
      'TOO_MANY_DRAFTS',
      'TOO_MANY_SCHEDULED_NOTES',
      'NO_SUCH_NOTE_DRAFT',
      'CONTAINS_PROHIBITED_WORDS',
      'CANNOT_RENOTE_DUE_TO_VISIBILITY',
      'MAX_FILE_SIZE_EXCEEDED',
      'ALREADY_FAVORITED',
    ]) {
      expect(misskeyErrorReason(code), isNotEmpty, reason: code);
    }
    expect(misskeyErrorReason('NOT_A_REAL_CODE'), isNull);
  });
}
