import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// ハッシュタグ・リスト・チャンネルの続き読みが [OlderCursorPaging] に委譲して
/// いることを見る (#1293)。
///
/// ⚠⚠ **集約の再発は「壊れること」ではなく「使わなくなること」として現れる**
/// （`docs/CLAUDE.md`「ソース検査ガードの書き方」・#1083-A）。3 本の続き読みは
/// v2.3 で `loadOlderPages` に寄せた（#1292）。どれかが自前の続き読みへ戻ると、
/// 集約先の守り（重複除去・再試行と `loadMoreError`・Sentry の site）を直しても、
/// その画面には黙って効かなくなる。
void main() {
  const files = {
    'hashtag': 'lib/src/provider/hashtag_provider.dart',
    'list': 'lib/src/provider/list_provider.dart',
    'channel': 'lib/src/provider/channel_provider.dart',
  };

  group('判定（合成ソース）', () {
    test('loadOlderPages を呼ぶ loadMore は委譲している', () {
      expect(
        loadMoreDelegates('''
  Future<void> loadMore() async {
    final adapter = ref.read(x);
    await loadOlderPages(site: 'list.loadMore', pageSize: 20, fetch: f);
  }
'''),
        isTrue,
      );
    });

    test('⚠⚠ 自前で続き読みを組んでいたら委譲していない', () {
      expect(
        loadMoreDelegates('''
  Future<void> loadMore() async {
    state = AsyncData(current.copyWith(isLoadingMore: true));
    final older = await adapter.getListTimeline(id);
  }
'''),
        isFalse,
      );
    });

    test('コメントの中に名前があるだけなら委譲していない', () {
      expect(
        loadMoreDelegates('''
  Future<void> loadMore() async {
    // loadOlderPages( はやめた
    final older = await adapter.getListTimeline(id);
  }
'''),
        isFalse,
      );
    });

    test('loadMore が無ければ委譲していない（走査の空振りを緑にしない）', () {
      expect(loadMoreDelegates('void other() {}'), isFalse);
    });
  });

  for (final entry in files.entries) {
    test('⚠⚠ ${entry.key} の続き読みは loadOlderPages に委譲している', () {
      final file = File(entry.value);
      expect(file.existsSync(), isTrue, reason: '走査の対象が無い（パスを確かめる）');
      final source = file.readAsStringSync();
      expect(
        maskComments(source),
        contains('OlderCursorPaging<'),
        reason: 'OlderCursorPaging を mix していない',
      );
      expect(loadMoreDelegates(source), isTrue);
    });
  }
}

/// `loadMore()` の本体が `loadOlderPages(` を呼んでいるか。コメントは落として見る。
bool loadMoreDelegates(String source) {
  final masked = maskComments(source);
  final head = RegExp(
    r'Future<void>\s+loadMore\(\)\s*async\s*\{',
  ).firstMatch(masked);
  if (head == null) return false;
  var depth = 0;
  for (var i = head.end - 1; i < masked.length; i++) {
    final c = masked[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) {
        return masked.substring(head.end, i).contains('loadOlderPages(');
      }
    }
  }
  return false;
}
