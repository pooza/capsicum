import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// 添付の読み込み中に敷く色の対応づけ (#1186)。
void main() {
  const blurhash = 'LEHV6nWB2yk8pyo0adR*.7kCMdnj'; // 平均色 0xFF979695

  group('Misskey', () {
    Map<String, dynamic> file({Object? avgColor, String? blurhash}) => {
      'id': 'f1',
      'name': 'a.png',
      'type': 'image/png',
      'url': 'https://example.test/a.png',
      'isSensitive': false,
      'blurhash': ?blurhash,
      'properties': {'avgColor': ?avgColor},
    };

    test('⚠ avgColor を先に使う', () {
      final a = MisskeyDriveFile.fromJson(
        file(avgColor: 'rgb(18,52,86)', blurhash: blurhash),
      ).toCapsicum();
      expect(a.placeholderColor, 0xFF123456);
    });

    test('avgColor が無ければ blurhash の平均色', () {
      final a = MisskeyDriveFile.fromJson(
        file(blurhash: blurhash),
      ).toCapsicum();
      expect(a.placeholderColor, 0xFF979695);
    });

    test('どちらも無ければ null（音声など）', () {
      final json = file()..remove('properties');
      expect(
        MisskeyDriveFile.fromJson(json).toCapsicum().placeholderColor,
        isNull,
      );
    });
  });

  group('Mastodon', () {
    test('blurhash の平均色を使う', () {
      final a = MastodonMediaAttachment.fromJson({
        'id': 'm1',
        'type': 'image',
        'url': 'https://example.test/a.png',
        'blurhash': blurhash,
      }).toCapsicum();
      expect(a.placeholderColor, 0xFF979695);
    });

    test('blurhash が無ければ null', () {
      final a = MastodonMediaAttachment.fromJson({
        'id': 'm1',
        'type': 'audio',
        'url': 'https://example.test/a.mp3',
      }).toCapsicum();
      expect(a.placeholderColor, isNull);
    });
  });
}
