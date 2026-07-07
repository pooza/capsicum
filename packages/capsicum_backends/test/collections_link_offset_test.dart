import 'package:capsicum_backends/src/mastodon/client.dart';
import 'package:test/test.dart';

/// #802 Collections の offset ページング。Link ヘッダ rel="next" から次ページの
/// offset を取り出す [parseNextOffsetFromLink] を検証する。ここが崩れると無限
/// スクロールが止まる／終端で回り続ける。
void main() {
  group('parseNextOffsetFromLink', () {
    test('rel="next" の offset を取り出す', () {
      const link =
          '<https://h/api/v1/accounts/1/collections?offset=40&limit=20>; '
          'rel="next", '
          '<https://h/api/v1/accounts/1/collections?offset=0&limit=20>; '
          'rel="prev"';
      expect(parseNextOffsetFromLink(link), 40);
    });

    test('next が無ければ null（終端）', () {
      const link =
          '<https://h/api/v1/accounts/1/collections?offset=0&limit=20>; '
          'rel="prev"';
      expect(parseNextOffsetFromLink(link), isNull);
    });

    test('Link ヘッダ自体が無ければ null', () {
      expect(parseNextOffsetFromLink(null), isNull);
    });

    test('offset=0 の next も取り出せる（0 は終端ではない）', () {
      const link =
          '<https://h/api/v1/accounts/1/in_collections?offset=0>; rel="next"';
      expect(parseNextOffsetFromLink(link), 0);
    });

    test('prev だけに offset があっても next を優先し null にしない誤爆をしない', () {
      // next に offset が無い（想定外）ケースは null（prev の offset を拾わない）。
      const link =
          '<https://h/api/v1/accounts/1/collections?limit=20>; rel="next", '
          '<https://h/api/v1/accounts/1/collections?offset=20>; rel="prev"';
      expect(parseNextOffsetFromLink(link), isNull);
    });
  });
}
