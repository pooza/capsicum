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

  /// #976: Mastodon 側の英語素通しと、モロヘイヤ独自 API の `errors` 配列。
  ///
  /// ⚠ **プリセット 5 サーバーのうち 3 つが Mastodon**なので、素通しにすると
  /// 多数派の環境ほど英語が出る。Misskey 側は `error.code` を丁寧に日本語化
  /// しているのに、こちらだけ英語のまま流していた。
  group('Mastodon 形（#976）', () {
    /// ⚠⚠ **文面は Mastodon 本体からそのまま持ってくること。**
    /// 初版はここでコード側と同じ Rails 既定形（`is too long (maximum is N
    /// characters)`）を組み立てて assert していたため、**実機では一度も発火
    /// しないのにテストは緑**という状態だった（v1.60 のリリース前レビューで検出）。
    ///
    /// 本文長超過は `StatusLengthValidator` が専用の I18n キーを使う:
    /// `app/validators/status_length_validator.rb` →
    /// `statuses.over_character_limit` = `character limit of %{max} exceeded`。
    test('本文の長さ超過は日本語にし、上限値は文面から拾う', () {
      // ⚠ 数字を決め打ちしない。上限はサーバー設定で変わる。
      expect(
        upstreamErrorMessage(
          _dioError({
            'error': 'Validation failed: Text character limit of 500 exceeded',
          }),
        ),
        '本文が長すぎます（上限 500 文字）',
      );
      expect(
        upstreamErrorMessage(
          _dioError({
            'error': 'Validation failed: Text character limit of 3000 exceeded',
          }),
        ),
        '本文が長すぎます（上限 3000 文字）',
      );
    });

    /// ActiveRecord 既定形も受ける。通報コメント等はこちらで返る
    /// （`Comment is too long (maximum is 1000 characters)`）。
    ///
    /// ⚠⚠ **フィールド名を無視して「本文」と訳さない（Codex P2 / PR #1023）。**
    /// 初版は 2 つの形を 1 本の正規表現で受けて一律「本文が長すぎます」に
    /// していて、**このテストがその誤訳を正解として固定していた**。本文
    /// (`:text`) は専用の I18n キーを使うので、この形では絶対に返らない。
    test('Rails 既定形はフィールド名で訳し分ける', () {
      expect(
        upstreamErrorMessage(
          _dioError({
            'error':
                'Validation failed: Comment is too long '
                '(maximum is 1000 characters)',
          }),
        ),
        'コメントが長すぎます（上限 1000 文字）',
      );
      expect(
        upstreamErrorMessage(
          _dioError({
            'error':
                'Validation failed: Description is too long '
                '(maximum is 10000 characters)',
          }),
        ),
        '説明が長すぎます（上限 10000 文字）',
      );
    });

    /// 知らないフィールドは名指ししない。`Avatar description` のように上流が
    /// 増やしうるので、当てずっぽうの名前を出すより中立の方が安全。
    test('素性の分からないフィールドは field 中立に倒す', () {
      expect(
        upstreamErrorMessage(
          _dioError({
            'error':
                'Validation failed: Avatar description is too long '
                '(maximum is 150 characters)',
          }),
        ),
        '入力が長すぎます（上限 150 文字）',
      );
    });

    test('定型句は日本語にする', () {
      expect(
        upstreamErrorMessage(_dioError({'error': 'Record not found'})),
        '対象が見つかりません。削除された可能性があります',
      );
      expect(
        upstreamErrorMessage(
          _dioError({'error': 'The access token is invalid'}),
        ),
        'ログイン情報が無効です。ログインし直してください',
      );
    });

    // ⚠ **未知の英語は落とさず出す。**意図した非対称（Misskey の未知は
    // `SOME_ERROR_CODE` という機械語だが、こちらは文章になっている）。
    test('未知の文言は英語のまま出す', () {
      expect(
        upstreamErrorMessage(
          _dioError({'error': 'Something unexpected happened upstream'}),
        ),
        'Something unexpected happened upstream',
      );
    });

    // モロヘイヤ独自 API のバリデーション失敗はこの形。`error` しか見て
    // いなかったため、予約投稿のタグ更新の主要な失敗ケースに #886 が効いて
    // いなかった。
    test('errors（複数形・配列）も理由として拾う', () {
      expect(
        upstreamErrorMessage(
          _dioError({
            'errors': ['タグは 10 個までです'],
          }, status: 422),
        ),
        'タグは 10 個までです',
      );
    });

    test('errors が複数なら先頭 + 件数に畳む', () {
      expect(
        upstreamErrorMessage(
          _dioError({
            'errors': ['タグは 10 個までです', 'タグに使えない文字が含まれています'],
          }, status: 422),
        ),
        'タグは 10 個までです（ほか 1 件）',
      );
    });

    test('errors が文字列でなければ拾わない', () {
      expect(
        upstreamErrorMessage(
          _dioError({
            'errors': [
              {'tags': 'too many'},
            ],
          }, status: 422),
        ),
        isNull,
      );
      expect(
        upstreamErrorMessage(_dioError({'errors': <String>[]}, status: 422)),
        isNull,
      );
    });

    // ⚠ 残骸の判定は `errors` 側にも効かせる。長すぎる / 複数行は SnackBar に
    // 載らないうえ、HTML 断片や stack trace の混入が疑われる。
    test('errors でも提示に耐えないものは落とす', () {
      expect(
        upstreamErrorMessage(
          _dioError({
            'errors': ['a' * 300],
          }, status: 422),
        ),
        isNull,
      );
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
