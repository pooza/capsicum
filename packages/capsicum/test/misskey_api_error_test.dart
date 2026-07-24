import 'package:capsicum/src/util/misskey_api_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #873: Misskey の `error.code`（ALREADY_LIKED / NOT_LIKED / YOUR_FLASH 等）を
/// 取り出せること。非べき等コードを「成功」として吸収する判断の土台。
void main() {
  DioException dioWith(Object? data) => DioException(
    requestOptions: RequestOptions(path: '/api/flash/like'),
    response: Response(
      requestOptions: RequestOptions(path: '/api/flash/like'),
      data: data,
    ),
  );

  test('error.code を取り出す', () {
    final e = dioWith({
      'error': {'code': 'ALREADY_LIKED', 'message': '...', 'id': 'x'},
    });
    expect(misskeyApiErrorCode(e), 'ALREADY_LIKED');
  });

  test('DioException 以外は null', () {
    expect(misskeyApiErrorCode(StateError('boom')), isNull);
  });

  test('error が Map でない（ボディ無し・文字列等）ときは null', () {
    expect(misskeyApiErrorCode(dioWith(null)), isNull);
    expect(misskeyApiErrorCode(dioWith('<html>502</html>')), isNull);
    expect(misskeyApiErrorCode(dioWith({'error': 'nope'})), isNull);
  });

  test('code が文字列でないときは null', () {
    expect(
      misskeyApiErrorCode(
        dioWith({
          'error': {'code': 42},
        }),
      ),
      isNull,
    );
  });
}
