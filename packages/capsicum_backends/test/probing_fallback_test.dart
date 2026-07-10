import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockDio extends Mock implements Dio {}

Response<dynamic> _resp(String path, int status, dynamic data) => Response(
  requestOptions: RequestOptions(path: path),
  statusCode: status,
  data: data,
);

DioException _err(
  String path, {
  required DioExceptionType type,
  Response<dynamic>? response,
}) => DioException(
  requestOptions: RequestOptions(path: path),
  type: type,
  response: response,
);

const _host = 'fork.example';
const _nodeInfoUrl = 'https://$_host/.well-known/nodeinfo';
const _metaUrl = 'https://$_host/api/meta';
const _instanceUrl = 'https://$_host/api/v1/instance';

/// NodeInfo を 404（未提供）にして必ずフォールバックへ落とす。
void _stubNodeInfoMissing(_MockDio dio) {
  when(() => dio.get<dynamic>(_nodeInfoUrl)).thenThrow(
    _err(
      _nodeInfoUrl,
      type: DioExceptionType.badResponse,
      response: _resp(_nodeInfoUrl, 404, null),
    ),
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  late _MockDio dio;

  setUp(() {
    dio = _MockDio();
  });

  test('NodeInfo 空振り時に Misskey /api/meta で判定する (#723)', () async {
    _stubNodeInfoMissing(dio);
    when(
      () => dio.post<dynamic>(_metaUrl, data: any(named: 'data')),
    ).thenAnswer((_) async => _resp(_metaUrl, 200, {'version': '2025.4.1'}));

    final result = await probeInstance(dio, _host);

    expect(result, isNotNull);
    expect(result!.type, BackendType.misskey);
    expect(result.softwareVersion, '2025.4.1');
    // 本家名は取れていないので softwareName は null（latest 追従ゲートを点けない）。
    expect(result.softwareName, isNull);
    // Mastodon エンドポイントは Misskey がヒットした時点で叩かない。
    verifyNever(() => dio.get<dynamic>(_instanceUrl));
  });

  test('Misskey 非該当時は Mastodon /api/v1/instance で判定する (#723)', () async {
    _stubNodeInfoMissing(dio);
    // Misskey ではない → /api/meta は 404。
    when(() => dio.post<dynamic>(_metaUrl, data: any(named: 'data'))).thenThrow(
      _err(
        _metaUrl,
        type: DioExceptionType.badResponse,
        response: _resp(_metaUrl, 404, null),
      ),
    );
    when(
      () => dio.get<dynamic>(_instanceUrl),
    ).thenAnswer((_) async => _resp(_instanceUrl, 200, {'version': '4.3.1'}));

    final result = await probeInstance(dio, _host);

    expect(result, isNotNull);
    expect(result!.type, BackendType.mastodon);
    expect(result.softwareVersion, '4.3.1');
    expect(result.softwareName, isNull);
  });

  test('応答はあるが両エンドポイント非該当なら null（未対応）', () async {
    _stubNodeInfoMissing(dio);
    when(() => dio.post<dynamic>(_metaUrl, data: any(named: 'data'))).thenThrow(
      _err(
        _metaUrl,
        type: DioExceptionType.badResponse,
        response: _resp(_metaUrl, 404, null),
      ),
    );
    when(() => dio.get<dynamic>(_instanceUrl)).thenThrow(
      _err(
        _instanceUrl,
        type: DioExceptionType.badResponse,
        response: _resp(_instanceUrl, 404, null),
      ),
    );

    final result = await probeInstance(dio, _host);
    expect(result, isNull);
  });

  test('全経路が到達不能なら例外を投げる（接続失敗を surface）', () async {
    when(
      () => dio.get<dynamic>(_nodeInfoUrl),
    ).thenThrow(_err(_nodeInfoUrl, type: DioExceptionType.connectionError));
    when(
      () => dio.post<dynamic>(_metaUrl, data: any(named: 'data')),
    ).thenThrow(_err(_metaUrl, type: DioExceptionType.connectionError));
    when(
      () => dio.get<dynamic>(_instanceUrl),
    ).thenThrow(_err(_instanceUrl, type: DioExceptionType.connectionError));

    expect(() => probeInstance(dio, _host), throwsA(isA<Exception>()));
  });
}
