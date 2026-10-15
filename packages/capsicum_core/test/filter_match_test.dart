import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #1289: フィルターは適用先（context）を見て解決する。
///
/// ⚠⚠ 以前は Mastodon の `filtered[]` の `filter_action` と最初の `title` だけを
/// 読み、全画面で効かせていた。「通知だけ」のフィルターがホームでも効いていた。
void main() {
  const homeHide = FilterMatch(
    action: FilterAction.hide,
    title: 'ネタバレ',
    contexts: {FilterContext.home},
  );
  const notificationsWarn = FilterMatch(
    action: FilterAction.warn,
    title: '実況',
    contexts: {FilterContext.notifications},
  );

  group('適用先', () {
    test('⚠⚠ 見ている画面の適用先に無いフィルターは効かない', () {
      expect(
        resolveFilterMatches([notificationsWarn], FilterContext.home),
        isNull,
      );
    });

    test('見ている画面の適用先にあるフィルターは効く', () {
      final verdict = resolveFilterMatches([
        notificationsWarn,
      ], FilterContext.notifications);
      expect(verdict?.action, FilterAction.warn);
      expect(verdict?.title, '実況');
    });

    test('適用先の無いもの（Misskey のワードミュート）は全画面で効く', () {
      const misskey = FilterMatch(action: FilterAction.warn);
      for (final context in FilterContext.values) {
        expect(
          resolveFilterMatches([misskey], context)?.action,
          FilterAction.warn,
          reason: '$context',
        );
      }
    });

    test('⚠ 知らない適用先だけが並んだ（空集合の）ものはどこにも効かない', () {
      const unknownOnly = FilterMatch(action: FilterAction.hide, contexts: {});
      for (final context in FilterContext.values) {
        expect(resolveFilterMatches([unknownOnly], context), isNull);
      }
    });

    test('画面の種別が分からない（null）ときは適用先を問わない', () {
      expect(
        resolveFilterMatches([notificationsWarn], null)?.action,
        FilterAction.warn,
      );
    });
  });

  group('動作の強さ', () {
    const blurHome = FilterMatch(
      action: FilterAction.blur,
      contexts: {FilterContext.home},
    );
    const warnHome = FilterMatch(
      action: FilterAction.warn,
      contexts: {FilterContext.home},
    );

    test('hide があれば hide', () {
      expect(
        resolveFilterMatches([
          warnHome,
          homeHide,
          blurHome,
        ], FilterContext.home)?.action,
        FilterAction.hide,
      );
    });

    test('blur だけなら blur（本文は見せ、メディアだけぼかす）', () {
      expect(
        resolveFilterMatches([blurHome], FilterContext.home)?.action,
        FilterAction.blur,
      );
    });

    // ⚠ warn は本文ごと畳む。blur に負けると本文が見えてしまう。
    test('⚠ warn と blur が両方なら warn（本文を畳むほうが強い）', () {
      expect(
        resolveFilterMatches([blurHome, warnHome], FilterContext.home)?.action,
        FilterAction.warn,
      );
    });

    test('⚠ weakenHide は hide を warn にする（詳細・ブックマーク・お気に入り・検索）', () {
      expect(
        resolveFilterMatches(
          [homeHide],
          FilterContext.home,
          weakenHide: true,
        )?.action,
        FilterAction.warn,
      );
    });

    test('weakenHide は hide 以外を変えない', () {
      expect(
        resolveFilterMatches(
          [blurHome],
          FilterContext.home,
          weakenHide: true,
        )?.action,
        FilterAction.blur,
      );
    });
  });

  group('タイトル', () {
    test('採ったフィルターのタイトルを「、」で連結する（重複は 1 回）', () {
      const a = FilterMatch(action: FilterAction.warn, title: 'A');
      const b = FilterMatch(action: FilterAction.warn, title: 'B');
      const a2 = FilterMatch(action: FilterAction.warn, title: 'A');
      expect(
        resolveFilterMatches([a, b, a2], FilterContext.home)?.title,
        'A、B',
      );
    });

    test('⚠ 適用先で外れたフィルターのタイトルは入れない', () {
      expect(
        resolveFilterMatches([
          homeHide,
          notificationsWarn,
        ], FilterContext.home)?.title,
        'ネタバレ',
      );
    });

    test('タイトルが無ければ null', () {
      expect(
        resolveFilterMatches([
          const FilterMatch(action: FilterAction.warn),
        ], FilterContext.home)?.title,
        isNull,
      );
    });
  });

  test('Post.isHiddenIn は適用先で判定する', () {
    final post = Post(
      id: '1',
      postedAt: DateTime.utc(2026, 10, 15),
      author: const User(id: 'u', username: 'u'),
      filterMatches: const [homeHide],
    );
    expect(post.isHiddenIn(FilterContext.home), isTrue);
    expect(post.isHiddenIn(FilterContext.public), isFalse);
  });

  test('Post.copyWith は filterMatches を引き継ぐ', () {
    final post = Post(
      id: '1',
      postedAt: DateTime.utc(2026, 10, 15),
      author: const User(id: 'u', username: 'u'),
      filterMatches: const [homeHide],
    );
    expect(post.copyWith(bookmarked: true).filterMatches, [homeHide]);
  });
}
