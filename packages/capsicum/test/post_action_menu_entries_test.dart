import 'package:capsicum/src/ui/util/post_actions.dart';
import 'package:capsicum/src/ui/widget/desktop_menu_model.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #943: スレッド画面のデスクトップメニューに載せる「選択中の投稿への操作」。
///
/// 眼目は 2 つ。
///
/// 1. **未選択のときに押せないこと。** ↑ ↓ でまだ辿っていない状態で走ると、
///    どの投稿への操作か決まらないまま API を叩くことになる。
/// 2. **項目が消えずに並び続けること。** #912 / #939 と同じ判断で、選択のたびに
///    項目数が変わると場所が動いて探しにくい。
void main() {
  PostActionAvailability availability({
    bool canReply = true,
    bool canQuote = true,
    bool canBoost = true,
    bool canUnrepeat = false,
    bool canFavorite = true,
    bool canBookmark = true,
  }) {
    final post = Post(
      id: 'p1',
      author: const User(id: 'u1', username: 'alice', host: 'example'),
      postedAt: DateTime(2026, 8, 15),
    );
    return PostActionAvailability(
      outerPost: post,
      targetPost: post,
      isOwn: false,
      isOwnRenote: false,
      canUnrepeat: canUnrepeat,
      canBoost: canBoost,
      canReply: canReply,
      canQuote: canQuote,
      canFavorite: canFavorite,
      canBookmark: canBookmark,
      canReact: false,
      boostLabel: 'ブースト',
      bookmarkLabel: 'ブックマーク',
    );
  }

  List<MenuEntry> build({
    PostActionAvailability? a,
    String boostLabel = 'ブースト',
    String bookmarkLabel = 'ブックマーク',
    List<String>? log,
  }) => buildPostActionMenuEntries(
    boostLabel: boostLabel,
    bookmarkLabel: bookmarkLabel,
    availability: a,
    onReply: () => log?.add('reply'),
    onQuote: () => log?.add('quote'),
    onBoost: () => log?.add('boost'),
    onUnboost: () => log?.add('unboost'),
    onFavorite: () => log?.add('favorite'),
    onBookmark: () => log?.add('bookmark'),
  );

  MenuActionEntry action(List<MenuEntry> entries, String label) =>
      entries.whereType<MenuActionEntry>().firstWhere((e) => e.label == label);

  test('項目はリプライ / 引用 / ブースト / 取り消し / お気に入り / ブックマーク', () {
    expect(build().whereType<MenuActionEntry>().map((e) => e.label), [
      'リプライ',
      '引用',
      'ブースト',
      'ブーストを取り消す',
      'お気に入り',
      'ブックマーク',
    ]);
  });

  test('ラベルはサーバー種別に追従する（Misskey ならリノート / お気に入り）', () {
    final entries = build(boostLabel: 'リノート', bookmarkLabel: 'お気に入り');

    expect(entries.whereType<MenuActionEntry>().map((e) => e.label), [
      'リプライ',
      '引用',
      'リノート',
      'リノートを取り消す',
      'お気に入り',
      // ⚠ Misskey では「お気に入り」が 2 つ並ぶ。Mastodon の Favorite と
      // Misskey のブックマーク相当が同名なのは docs/CLAUDE.md の機能マッピング
      // どおりで、実際には Misskey アダプタが FavoriteSupport を持たないため
      // 上の「お気に入り」は無効のまま出る。
      'お気に入り',
    ]);
  });

  group('未選択（↑ ↓ でまだ辿っていない）', () {
    test('全項目が無効', () {
      final entries = build(a: null);

      expect(
        entries.whereType<MenuActionEntry>().every((e) => e.onSelected == null),
        isTrue,
      );
    });

    test('項目は消えない（選択のたびに場所が動かない）', () {
      expect(
        build(a: null).whereType<MenuActionEntry>().length,
        build(a: availability()).whereType<MenuActionEntry>().length,
      );
    });
  });

  group('選択あり', () {
    test('条件を満たす操作だけが有効', () {
      final entries = build(a: availability());

      expect(action(entries, 'リプライ').onSelected, isNotNull);
      expect(action(entries, '引用').onSelected, isNotNull);
      expect(action(entries, 'ブースト').onSelected, isNotNull);
      expect(action(entries, 'お気に入り').onSelected, isNotNull);
      expect(action(entries, 'ブックマーク').onSelected, isNotNull);
      // 未ブーストなら取り消しは無効。
      expect(action(entries, 'ブーストを取り消す').onSelected, isNull);
    });

    /// ひかえめな公開より下（フォロワー限定・ダイレクト）はブーストできない。
    test('ブースト不可の投稿ではブーストが無効', () {
      final entries = build(a: availability(canBoost: false));

      expect(action(entries, 'ブースト').onSelected, isNull);
      expect(action(entries, 'リプライ').onSelected, isNotNull);
    });

    test('ブースト済みなら取り消しが有効', () {
      final entries = build(a: availability(canUnrepeat: true));

      expect(action(entries, 'ブーストを取り消す').onSelected, isNotNull);
    });

    /// Misskey は FavoriteSupport を持たない（リアクションで代替）。
    test('お気に入り非対応のサーバーでは無効', () {
      final entries = build(a: availability(canFavorite: false));

      expect(action(entries, 'お気に入り').onSelected, isNull);
      expect(action(entries, 'ブックマーク').onSelected, isNotNull);
    });

    test('引用不可の投稿では引用が無効', () {
      expect(
        action(build(a: availability(canQuote: false)), '引用').onSelected,
        isNull,
      );
    });

    test('各項目は対応するコールバックを呼ぶ', () {
      final log = <String>[];
      final entries = build(a: availability(canUnrepeat: true), log: log);

      for (final label in [
        'リプライ',
        '引用',
        'ブースト',
        'ブーストを取り消す',
        'お気に入り',
        'ブックマーク',
      ]) {
        action(entries, label).onSelected!();
      }

      expect(log, [
        'reply',
        'quote',
        'boost',
        'unboost',
        'favorite',
        'bookmark',
      ]);
    });
  });

  /// #835 の約束。画面側は選択に依存しない名前付きメソッドをテアオフで渡すので、
  /// **選択が変わらなければ値等価**になり、スレッド再取得のたびにメニューバー
  /// 全体が作り直されない。
  test('同じ条件・同じコールバックで組み直せば値等価になる', () {
    void noop() {}

    List<MenuEntry> make() => buildPostActionMenuEntries(
      boostLabel: 'ブースト',
      bookmarkLabel: 'ブックマーク',
      availability: availability(),
      onReply: noop,
      onQuote: noop,
      onBoost: noop,
      onUnboost: noop,
      onFavorite: noop,
      onBookmark: noop,
    );

    expect(sameMenuEntries(make(), make()), isTrue);
  });

  test('選択の有無が変われば値等価は崩れる（メニューが出し直される）', () {
    void noop() {}

    List<MenuEntry> make(PostActionAvailability? a) =>
        buildPostActionMenuEntries(
          boostLabel: 'ブースト',
          bookmarkLabel: 'ブックマーク',
          availability: a,
          onReply: noop,
          onQuote: noop,
          onBoost: noop,
          onUnboost: noop,
          onFavorite: noop,
          onBookmark: noop,
        );

    expect(sameMenuEntries(make(null), make(availability())), isFalse);
  });
}
