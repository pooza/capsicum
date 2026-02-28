import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio();
  });

  test('probe mastodon.social', () async {
    final result = await probeInstance(dio, 'mastodon.social');
    print('Result: $result');
    print('Type: ${result?.type}');
    expect(result, isNotNull);
    expect(result!.type, BackendType.mastodon);
  });

  test('probe misskey.io', () async {
    final result = await probeInstance(dio, 'misskey.io');
    print('Result: $result');
    print('Type: ${result?.type}');
    expect(result, isNotNull);
    expect(result!.type, BackendType.misskey);
  });
}
