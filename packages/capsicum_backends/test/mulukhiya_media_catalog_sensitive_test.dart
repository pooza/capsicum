import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:test/test.dart';

/// #1284: メディアカタログの閲覧注意・CW の印（モロヘイヤ 5.41.0〜）。
/// カタログは未認証で届く一覧で、ぼかすのはクライアントの責任なので、
/// 印を読み落とすと畳まれているはずのメディアがそのまま出る。
void main() {
  Map<String, dynamic> item({
    Object? sensitive = _absent,
    Object? spoilerText = _absent,
    Object? body = '本文',
  }) {
    return {
      'id': 123,
      'url': 'https://example.com/media/original.png',
      'thumbnail_url': 'https://example.com/media/small.png',
      'mediatype': 'image',
      if (!identical(sensitive, _absent)) 'sensitive': sensitive,
      'account': {'username': 'alice', 'display_name': 'Alice'},
      'status': {
        'body': body,
        'public_url': 'https://example.com/@alice/1',
        if (!identical(spoilerText, _absent)) 'spoiler_text': spoilerText,
      },
    };
  }

  test('閲覧注意の印を読む', () {
    final parsed = MediaCatalogItem.fromJson(
      item(sensitive: true, spoilerText: null),
    );
    expect(parsed.sensitive, isTrue);
    expect(parsed.spoilerText, isNull);
    expect(parsed.statusBody, '本文');
  });

  test('CW つきは文言を読み、本文が null でも落ちない', () {
    final parsed = MediaCatalogItem.fromJson(
      item(sensitive: true, spoilerText: 'ネタバレ', body: null),
    );
    expect(parsed.sensitive, isTrue);
    expect(parsed.spoilerText, 'ネタバレ');
    expect(parsed.statusBody, isNull);
  });

  test('印の無いメディアはぼかさない', () {
    final parsed = MediaCatalogItem.fromJson(
      item(sensitive: false, spoilerText: null),
    );
    expect(parsed.sensitive, isFalse);
    expect(parsed.spoilerText, isNull);
  });

  test('5.40.x 以前（キーが無い）は印なしとして読む', () {
    final parsed = MediaCatalogItem.fromJson(item());
    expect(parsed.sensitive, isFalse);
    expect(parsed.spoilerText, isNull);
    expect(parsed.id, '123');
    expect(parsed.accountUsername, 'alice');
    expect(parsed.statusPublicUrl, 'https://example.com/@alice/1');
  });

  test('空の CW の文言は無いものとして扱う', () {
    final parsed = MediaCatalogItem.fromJson(
      item(sensitive: true, spoilerText: '  '),
    );
    expect(parsed.sensitive, isTrue);
    expect(parsed.spoilerText, isNull);
  });

  test('status が無くても印は読める', () {
    final json = item(sensitive: true)..remove('status');
    final parsed = MediaCatalogItem.fromJson(json);
    expect(parsed.sensitive, isTrue);
    expect(parsed.spoilerText, isNull);
    expect(parsed.statusBody, isNull);
  });
}

const _absent = Object();
