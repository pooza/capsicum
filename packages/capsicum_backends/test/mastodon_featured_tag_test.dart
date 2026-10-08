import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1075: プロフィールの掲載タグ（`GET /api/v1/accounts/:id/featured_tags`）。
void main() {
  test('本家の形（件数は文字列・日付だけ）を読む', () {
    final tag = MastodonFeaturedTag.fromJson({
      'id': '1',
      'name': 'PreCure',
      'url': 'https://mstdn.example/@me/tagged/precure',
      'statuses_count': '42',
      'last_status_at': '2026-09-04',
    }).toCapsicum();
    expect(tag.id, '1', reason: '外すときに使う');
    expect(tag.name, 'PreCure', reason: '表示用の大文字小文字を保つ');
    expect(tag.statusesCount, 42);
    expect(tag.lastStatusAt, DateTime(2026, 9, 4));
  });

  test('件数が数値で来ても読む・日付が無くても落とさない', () {
    final tag = MastodonFeaturedTag.fromJson({
      'id': '2',
      'name': 'delmulin',
      'statuses_count': 7,
      'last_status_at': null,
    }).toCapsicum();
    expect(tag.statusesCount, 7);
    expect(tag.lastStatusAt, isNull);
  });

  test('読めない値は 0 / null に倒し、タグそのものは残す', () {
    final tag = MastodonFeaturedTag.fromJson({
      'id': '3',
      'name': 'x',
      'statuses_count': 'many',
      'last_status_at': 'yesterday',
    }).toCapsicum();
    expect(tag.name, 'x');
    expect(tag.statusesCount, 0);
    expect(tag.lastStatusAt, isNull);
  });
}
