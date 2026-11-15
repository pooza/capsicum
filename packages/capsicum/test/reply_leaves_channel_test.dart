import 'package:capsicum/src/ui/util/reply_compose_extra.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1380: Misskey のチャンネルの中のリノートから返信すると、返信はチャンネルの
/// 外に出る（サーバーの仕様）。送る前に分かるよう、投稿画面に注意書きを出す。
const _author = User(id: 'u', username: 'someone');

Post _post(String id, {String? channelId, String? channelName, Post? reblog}) =>
    Post(
      id: id,
      postedAt: DateTime.utc(2026, 11, 12),
      author: _author,
      channelId: channelId,
      channelName: channelName,
      reblog: reblog,
    );

/// 返信の入口に `'replyTo':` を直に書いてよいファイル。
///
/// - `reply_compose_extra.dart`: 正本
/// - `notification_tile.dart`: 通知にはリノートの外側（押した場所）が無い
const _allowed = {'reply_compose_extra.dart', 'notification_tile.dart'};

/// `'replyTo':` を直に書いているファイル名（コメントは除く）。
List<String> directReplyToOffenders(Map<String, String> sources) => [
  for (final MapEntry(:key, :value) in sources.entries)
    if (!_allowed.contains(key) &&
        RegExp(r'''['"]replyTo['"]\s*:''').hasMatch(maskComments(value)))
      key,
];

void main() {
  group('replyLeavesChannel', () {
    test('チャンネルの外の投稿をチャンネルへリノートしたもの → チャンネル名', () {
      final inner = _post('atf5ccywta');
      final outer = _post(
        'atf5d1nxtr',
        channelId: 'a2ip67g6mr',
        channelName: 'エア番組実況',
        reblog: inner,
      );
      expect(replyLeavesChannel(outer: outer, target: inner), 'エア番組実況');
      expect(replyComposeExtra(outer: outer, target: inner), {
        'replyTo': inner,
        'replyLeavesChannel': 'エア番組実況',
      });
    });

    test('チャンネル名が不明なら空文字（出すことは出す）', () {
      final inner = _post('i');
      final outer = _post('o', channelId: 'c', reblog: inner);
      expect(replyLeavesChannel(outer: outer, target: inner), '');
    });

    test('⚠ チャンネルの投稿そのものへの返信では出さない（チャンネルに入る）', () {
      final post = _post('p', channelId: 'c', channelName: 'ch');
      expect(replyLeavesChannel(outer: post, target: post), isNull);
      expect(replyComposeExtra(outer: post, target: post), {'replyTo': post});
    });

    test('⚠ 中身もチャンネルにあるリノートでは出さない', () {
      final inner = _post('i', channelId: 'c', channelName: 'ch');
      final outer = _post(
        'o',
        channelId: 'c',
        channelName: 'ch',
        reblog: inner,
      );
      expect(replyLeavesChannel(outer: outer, target: inner), isNull);
    });

    test('⚠ チャンネルの外のリノートでは出さない', () {
      final inner = _post('i');
      final outer = _post('o', reblog: inner);
      expect(replyLeavesChannel(outer: outer, target: inner), isNull);
    });
  });

  test('注意書きの文面', () {
    expect(
      replyLeavesChannelMessage('エア番組実況'),
      'この返信はチャンネル「エア番組実況」の外に投稿されます。'
      'リノートの元の投稿がチャンネルの外にあるためです。',
    );
    expect(replyLeavesChannelMessage(''), startsWith('この返信はチャンネルの外に'));
  });

  // 集約したものは「委譲していること」まで見る（docs/CLAUDE.md）。入口が
  // `{'replyTo': targetPost}` へ戻ると、注意書きが黙って出なくなる。
  group('⚠ 返信の入口は replyComposeExtra を通す', () {
    final files = sourceFiles('lib', skipGenerated: true);
    final sources = {
      for (final f in files) f.uri.pathSegments.last: f.readAsStringSync(),
    };

    test('走査が空振りしていない（既知の入口と正本が含まれる）', () {
      expect(files.length, greaterThan(100));
      for (final name in [
        'post_tile.dart',
        'post_touch_action_row.dart',
        'post_detail_screen.dart',
        'reply_compose_extra.dart',
      ]) {
        expect(sources.containsKey(name), isTrue, reason: name);
      }
      expect(sources['post_tile.dart'], contains('replyComposeExtra('));
      expect(
        sources['post_touch_action_row.dart'],
        contains('replyComposeExtra('),
      );
      expect(
        sources['post_detail_screen.dart'],
        contains('replyComposeExtra('),
      );
    });

    test('lib に直書きの入口が無い', () {
      expect(directReplyToOffenders(sources), isEmpty);
    });

    test('判定: 直書きは当たり、コメントと許可したファイルは当たらない', () {
      expect(
        directReplyToOffenders({
          'a.dart': "push('/compose', extra: {'replyTo': p});",
          'b.dart': '// extra: {"replyTo": p}',
          'notification_tile.dart': "{'replyTo': p}",
          'c.dart': 'replyComposeExtra(outer: o, target: t)',
        }),
        ['a.dart'],
      );
    });
  });
}
