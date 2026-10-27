import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

/// #1337: Akkoma / Pleroma を「Mastodon の一種」として NodeInfo の段で判定し、
/// ソフトウェア名を覚える（Sentry で本家と見分けるため）。
class _MockDio extends Mock implements Dio {}

Response<dynamic> _resp(String path, dynamic data) => Response(
  requestOptions: RequestOptions(path: path),
  statusCode: 200,
  data: data,
);

/// [host] の NodeInfo が `software.name = name` を返すようにする。
void _stubNodeInfo(_MockDio dio, String host, String name) {
  final wellKnown = 'https://$host/.well-known/nodeinfo';
  final info = 'https://$host/nodeinfo/2.0';
  when(() => dio.get<dynamic>(wellKnown)).thenAnswer(
    (_) async => _resp(wellKnown, {
      'links': [
        {
          'rel': 'http://nodeinfo.diaspora.software/ns/schema/2.0',
          'href': info,
        },
      ],
    }),
  );
  when(() => dio.get<dynamic>(info)).thenAnswer(
    (_) async => _resp(info, {
      'software': {'name': name, 'version': '3.20.1'},
    }),
  );
}

void main() {
  for (final name in ['akkoma', 'pleroma']) {
    test('$name は NodeInfo の段で Mastodon と判定し、名前を残す', () async {
      final dio = _MockDio();
      final host = '$name.example';
      _stubNodeInfo(dio, host, name);

      final probe = await probeInstance(dio, host);

      expect(probe?.type, BackendType.mastodon);
      expect(probe?.softwareName, name);
      expect(knownSoftwareName(host), name);
    });
  }

  test('⚠ 種別が分からない名前も覚える（Sentry で見分けるため）', () async {
    final dio = _MockDio();
    const host = 'gts.example';
    _stubNodeInfo(dio, host, 'GoToSocial');
    // NodeInfo で決まらないので後段へ落ちる。ここでは後段も 404 で空振りさせる。
    DioException notFound(String path) => DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 404,
      ),
    );
    when(
      () => dio.post<dynamic>(any(), data: any(named: 'data')),
    ).thenThrow(notFound('/api/meta'));
    when(
      () => dio.get<dynamic>('https://$host/api/v1/instance'),
    ).thenThrow(notFound('/api/v1/instance'));

    expect(await probeInstance(dio, host), isNull);

    expect(knownSoftwareName(host), 'gotosocial');
  });

  test('読んでいない host は null', () {
    expect(knownSoftwareName('never-probed.example'), isNull);
  });
}
