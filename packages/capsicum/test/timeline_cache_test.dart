import 'dart:convert';
import 'dart:io';

import 'package:capsicum/src/service/timeline_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// #890 item2: 起動時に前回のホーム TL を先出しするためのディスクキャッシュ。
///
/// 「使えないものは使わない」側の判定（文脈違い・期限切れ・壊れている）を
/// 落とすと、別アカウントの投稿や数日前の一覧を一瞬出すことになるので、
/// 拒否の条件を重点的に固める。
void main() {
  late Directory dir;
  final now = DateTime.utc(2026, 7, 31, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('capsicum_timeline_cache');
    TimelineCache.directoryOverride = dir.path;
  });

  tearDown(() {
    TimelineCache.directoryOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  List<Map<String, dynamic>> raw(int count) => [
    for (var i = 0; i < count; i++) {'id': '$i', 'content': 'post $i'},
  ];

  test('保存したものを同じ contextKey で読み戻せる', () async {
    await TimelineCache.save('acct|tl:home', raw(2), now: now);

    final loaded = await TimelineCache.load('acct|tl:home', now: now);

    expect(loaded, isNotNull);
    expect(loaded!.map((e) => e['id']), ['0', '1']);
  });

  test('contextKey が違えば使わない（別アカウント / 別 TL の取り違え防止）', () async {
    await TimelineCache.save('acct-a|tl:home', raw(2), now: now);

    expect(await TimelineCache.load('acct-b|tl:home', now: now), isNull);
    expect(await TimelineCache.load('acct-a|tl:local', now: now), isNull);
  });

  test('maxAge を超えたキャッシュは使わない', () async {
    await TimelineCache.save('acct|tl:home', raw(2), now: now);

    final justInside = now.add(TimelineCache.maxAge);
    final justOutside = now.add(
      TimelineCache.maxAge + const Duration(minutes: 1),
    );

    expect(
      await TimelineCache.load('acct|tl:home', now: justInside),
      isNotNull,
    );
    expect(await TimelineCache.load('acct|tl:home', now: justOutside), isNull);
  });

  test('保存件数は maxPosts で頭打ちにする', () async {
    await TimelineCache.save(
      'acct|tl:home',
      raw(TimelineCache.maxPosts + 5),
      now: now,
    );

    final loaded = await TimelineCache.load('acct|tl:home', now: now);

    expect(loaded, hasLength(TimelineCache.maxPosts));
  });

  test('空の保存要求はファイルを作らない', () async {
    await TimelineCache.save('acct|tl:home', const [], now: now);

    expect(await TimelineCache.load('acct|tl:home', now: now), isNull);
  });

  test('壊れたファイルは例外にせず null を返す', () async {
    await TimelineCache.save('acct|tl:home', raw(1), now: now);
    final file = File('${dir.path}/home_timeline_cache.json');
    await file.writeAsString('{ this is not json');

    expect(await TimelineCache.load('acct|tl:home', now: now), isNull);
  });

  test('posts が配列でない壊れ方でも null を返す', () async {
    final file = File('${dir.path}/home_timeline_cache.json');
    await file.writeAsString(
      jsonEncode({
        'contextKey': 'acct|tl:home',
        'savedAt': now.toIso8601String(),
        'posts': 'broken',
      }),
    );

    expect(await TimelineCache.load('acct|tl:home', now: now), isNull);
  });

  test('clear で消える', () async {
    await TimelineCache.save('acct|tl:home', raw(2), now: now);
    await TimelineCache.clear();

    expect(await TimelineCache.load('acct|tl:home', now: now), isNull);
  });

  test('キャッシュが無い状態の読み出しは null', () async {
    expect(await TimelineCache.load('acct|tl:home', now: now), isNull);
  });
}
