import 'package:capsicum/src/ui/util/annict_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1310: Annict 系の失敗のうち、どれを Sentry のイベントにするか。
///
/// ⚠ 401 / 403 をイベントにしない既存の判断（通常運用のノイズ）は崩さない。
/// そのうえで、#1305 の 404 のような「行き先の取り違え」を release でも拾う。
void main() {
  final request = RequestOptions(path: '/mulukhiya/api/annict/works');

  DioException withStatus(int status) => DioException(
    requestOptions: request,
    response: Response(requestOptions: request, statusCode: status),
    type: DioExceptionType.badResponse,
  );

  test('401 / 403（未連携・トークン失効）はイベントにしない', () {
    expect(annictFailureIsEvent(withStatus(401)), isFalse);
    expect(annictFailureIsEvent(withStatus(403)), isFalse);
  });

  test('409（冪等性ロック・#1176）はイベントにしない', () {
    expect(annictFailureIsEvent(withStatus(409)), isFalse);
  });

  test('回線の失敗（状態コードが無い）はイベントにしない', () {
    expect(
      annictFailureIsEvent(
        DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        ),
      ),
      isFalse,
    );
    expect(
      annictFailureIsEvent(
        DioException(
          requestOptions: request,
          type: DioExceptionType.receiveTimeout,
        ),
      ),
      isFalse,
    );
  });

  test('⚠ 404（#1305 の行き先の取り違え）と 5xx はイベントにする', () {
    expect(annictFailureIsEvent(withStatus(404)), isTrue);
    expect(annictFailureIsEvent(withStatus(500)), isTrue);
    expect(annictFailureIsEvent(withStatus(502)), isTrue);
  });

  test('Dio 以外の例外（応答の形が合わない等）はイベントにする', () {
    expect(annictFailureIsEvent(const FormatException('bad')), isTrue);
  });
}
