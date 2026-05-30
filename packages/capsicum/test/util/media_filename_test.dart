import 'package:capsicum/src/util/media_filename.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment _att({
  required AttachmentType type,
  required String url,
  String? name,
}) => Attachment(id: '1', type: type, url: url, name: name);

void main() {
  group('suggestedMediaFileName', () {
    test('name があればそれを優先する', () {
      final r = suggestedMediaFileName(
        _att(
          type: AttachmentType.image,
          url: 'https://example.com/files/abc123',
          name: 'cure_ishimatsu.png',
        ),
      );
      expect(r, 'cure_ishimatsu.png');
    });

    test('name が無ければ URL 末尾セグメントを使う', () {
      final r = suggestedMediaFileName(
        _att(
          type: AttachmentType.image,
          url: 'https://example.com/media/original/photo.webp',
        ),
      );
      expect(r, 'photo.webp');
    });

    test('URL のクエリ・フラグメントは除去される', () {
      final r = suggestedMediaFileName(
        _att(
          type: AttachmentType.image,
          url: 'https://example.com/media/photo.jpg?token=secret#frag',
        ),
      );
      expect(r, 'photo.jpg');
    });

    test('拡張子の無い URL セグメントには種別から拡張子を補う (image→.png)', () {
      final r = suggestedMediaFileName(
        _att(
          type: AttachmentType.image,
          url: 'https://example.com/files/abcdef0123',
        ),
      );
      expect(r, 'abcdef0123.png');
    });

    test('video は .mp4 を補う', () {
      final r = suggestedMediaFileName(
        _att(type: AttachmentType.video, url: 'https://example.com/v/clip'),
      );
      expect(r, 'clip.mp4');
    });

    test('gifv も .mp4 を補う', () {
      final r = suggestedMediaFileName(
        _att(type: AttachmentType.gifv, url: 'https://example.com/v/anim'),
      );
      expect(r, 'anim.mp4');
    });

    test('audio は .mp3 を補う', () {
      final r = suggestedMediaFileName(
        _att(type: AttachmentType.audio, url: 'https://example.com/a/sound'),
      );
      expect(r, 'sound.mp3');
    });

    test('name / URL ともに無効なら capsicum_media + 種別拡張子', () {
      final r = suggestedMediaFileName(
        _att(type: AttachmentType.image, url: 'https://example.com/'),
      );
      expect(r, 'capsicum_media.png');
    });

    test('unknown 種別は拡張子無しの fallback 名', () {
      final r = suggestedMediaFileName(
        _att(type: AttachmentType.unknown, url: 'https://example.com/'),
      );
      expect(r, 'capsicum_media');
    });

    test('name にパス区切りが含まれても除去される', () {
      final r = suggestedMediaFileName(
        _att(
          type: AttachmentType.image,
          url: 'https://example.com/x',
          name: '../../etc/passwd.png',
        ),
      );
      expect(r, isNot(contains('/')));
      expect(r, '....etcpasswd.png');
    });
  });
}
