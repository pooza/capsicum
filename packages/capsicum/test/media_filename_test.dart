import 'package:capsicum/src/util/media_filename.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment _img({String? name, required String url}) =>
    Attachment(id: '1', type: AttachmentType.image, url: url, name: name);

void main() {
  group('rawMediaExtension — #779 (drag-out で既定 .png に倒さない)', () {
    test('元ファイル名の拡張子を小文字で返す', () {
      expect(
        rawMediaExtension(_img(name: 'PHOTO.JPG', url: 'https://x/a')),
        'jpg',
      );
    });

    test('名前が拡張子なしなら URL 末尾の拡張子で判定する', () {
      expect(
        rawMediaExtension(_img(name: 'no-ext', url: 'https://x/media.webp')),
        'webp',
      );
    });

    test('名前にも URL にも拡張子が無ければ null（.png に倒さない）', () {
      expect(
        rawMediaExtension(_img(url: 'https://x/media/abcdef0123456789')),
        isNull,
      );
    });

    test('クエリ・フラグメント付き URL でも拡張子を拾える', () {
      expect(
        rawMediaExtension(_img(url: 'https://x/a/pic.gif?v=2#frag')),
        'gif',
      );
    });

    test('拡張子らしくない長い末尾は拡張子とみなさない', () {
      expect(rawMediaExtension(_img(url: 'https://x/file.longsuffix')), isNull);
    });

    test('suggestedMediaFileName は従来どおり画像に既定 .png を補う（対比）', () {
      // rawMediaExtension は null を返すケースでも、保存用の推奨名は .png を付ける。
      // drag-out が前者を使うことで PNG 誤判定 (#779) を避ける。
      expect(
        suggestedMediaFileName(_img(url: 'https://x/media/abcdef0123456789')),
        endsWith('.png'),
      );
    });
  });
}
