import 'package:capsicum/src/ui/util/post_action_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 上流（モロヘイヤ経由）のエラーレスポンスを模した DioException を作る。
DioException _dioError(Object? body, {int status = 400}) {
  final options = RequestOptions(path: '/api/notes/create');
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

DioException _misskeyCode(String code, {int status = 400}) => _dioError({
  'error': {'code': code, 'message': 'msg', 'id': 'x', 'kind': 'client'},
}, status: status);

void main() {
  group('describePostActionError', () {
    test('400 + CANNOT_RENOTE_OUTSIDE_OF_CHANNEL は専用文言 (#923)', () {
      expect(
        describePostActionError(
          _misskeyCode('CANNOT_RENOTE_OUTSIDE_OF_CHANNEL'),
        ),
        'チャンネルの外へはブーストできません',
      );
    });

    test('400 + NO_SUCH_CHANNEL は専用文言 (#923)', () {
      expect(
        describePostActionError(_misskeyCode('NO_SUCH_CHANNEL')),
        '対象のチャンネルが見つかりません',
      );
    });

    test('400 でも未知 code は汎用文言に倒す', () {
      expect(
        describePostActionError(_misskeyCode('SOME_BRAND_NEW_CODE')),
        '操作に失敗しました',
      );
    });

    test('400 でもボディに error.code が無ければ汎用文言', () {
      expect(
        describePostActionError(_dioError({'error': 'plain string'})),
        '操作に失敗しました',
      );
    });

    test('403 は従来どおり権限・再ログイン案内（Misskey code より優先）', () {
      // Misskey が 403 + code を返しても、403 の一般案内を優先する。
      expect(
        describePostActionError(_misskeyCode('ACCESS_DENIED', status: 403)),
        '権限がありません。再ログインが必要な場合があります',
      );
    });

    test('500 は従来どおりサーバー内部エラー', () {
      expect(
        describePostActionError(_dioError(null, status: 500)),
        'サーバー内部エラーが発生しました。サーバー管理者にお問い合わせください',
      );
    });

    test('DioException 以外は汎用文言', () {
      expect(describePostActionError(Exception('x')), '操作に失敗しました');
    });
  });
}
