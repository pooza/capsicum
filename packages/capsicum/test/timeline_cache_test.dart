import 'dart:async';
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

  /// v1.53 リリース PR の Codex 指摘。
  ///
  /// 保存は `unawaited` で投げるので、ログアウトの [TimelineCache.clear] と競合する。
  /// 直列化しないと、clear が終わった後に遅れて write が完了し、**ログアウトした
  /// アカウントの生タイムラインがディスクに復活する**。
  test('保存中にログアウトしても、await した clear の後にファイルが復活しない', () async {
    // 保存を await せずに投げた直後に消す（ログアウトのタイミング）。
    unawaited(TimelineCache.save('acct|tl:home', raw(20), now: now));
    await TimelineCache.clear();

    expect(
      await TimelineCache.load('acct|tl:home', now: now),
      isNull,
      reason: 'clear を await した時点で、先に始まった保存も片付いている',
    );
    expect(
      File('${dir.path}/home_timeline_cache.json').existsSync(),
      isFalse,
      reason: 'ログアウトしたアカウントの投稿を端末に残さない',
    );
  });

  /// #914 §1: 保存先を Application Support からキャッシュ領域へ移した。
  ///
  /// 移しただけだと**旧ファイルは二度と読まれないまま残る**（新しい保存先を
  /// 使うので上書きもされない）。中身は生のホーム TL ＝ フォロワー限定・
  /// ダイレクトを含む投稿本文なので、置き去りにしてはいけない。
  group('旧保存先の後片付け (#914 §1)', () {
    late Directory legacyDir;

    setUp(() {
      legacyDir = Directory.systemTemp.createTempSync('capsicum_tl_cache_old');
      TimelineCache.legacyDirectoryOverride = legacyDir.path;
    });

    tearDown(() {
      TimelineCache.legacyDirectoryOverride = null;
      if (legacyDir.existsSync()) legacyDir.deleteSync(recursive: true);
    });

    File legacyFile() => File('${legacyDir.path}/home_timeline_cache.json');

    test('旧保存先に残ったキャッシュを消す', () async {
      legacyFile().writeAsStringSync(
        jsonEncode({
          'contextKey': 'acct|tl:home',
          'savedAt': now.toIso8601String(),
          'posts': raw(3),
        }),
      );

      await TimelineCache.clearLegacyLocation();

      expect(legacyFile().existsSync(), isFalse);
    });

    test('新しい保存先のキャッシュは巻き添えで消えない', () async {
      await TimelineCache.save('acct|tl:home', raw(2), now: now);
      legacyFile().writeAsStringSync('{}');

      await TimelineCache.clearLegacyLocation();

      expect(legacyFile().existsSync(), isFalse);
      expect(
        await TimelineCache.load('acct|tl:home', now: now),
        isNotNull,
        reason: '移行後の先出しが初回だけ効かなくなるのを防ぐ',
      );
    });

    test('旧保存先にファイルが無くても失敗しない（2 回目以降の起動）', () async {
      await TimelineCache.clearLegacyLocation();
      await TimelineCache.clearLegacyLocation();

      expect(legacyFile().existsSync(), isFalse);
    });

    test('旧ディレクトリ自体が無くても失敗しない', () async {
      legacyDir.deleteSync(recursive: true);

      await TimelineCache.clearLegacyLocation();
    });
  });
}
