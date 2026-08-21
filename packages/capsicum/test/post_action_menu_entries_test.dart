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
    bool supportsFavorite = true,
    bool supportsBookmark = true,
    List<String>? log,
  }) => buildPostActionMenuEntries(
    boostLabel: boostLabel,
    bookmarkLabel: bookmarkLabel,
    supportsFavorite: supportsFavorite,
    supportsBookmark: supportsBookmark,
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
    /// ⚠ **お気に入り非対応のサーバーは「無効」ではなく「非表示」になった**
    /// (#980)。`canFavorite` は `adapter is FavoriteSupport` だけで決まるので、
    /// 「対応しているのに今は押せない」という状態は存在しない。項目の有無は
    /// `supportsFavorite` が持ち、その検査は「概念の無い操作は隠す」group 側。
    ///
    /// ここは**ブックマークが巻き添えで消えていないこと**だけを見る。
    test('お気に入り非対応でもブックマークは残る', () {
      final entries = build(
        a: availability(canFavorite: false),
        supportsFavorite: false,
      );

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
      supportsFavorite: true,
      supportsBookmark: true,
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
          supportsFavorite: true,
          supportsBookmark: true,
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

  /// #980: バックエンドに概念が無い操作は「無効化して残す」ではなく隠す。
  ///
  /// Misskey は `FavoriteSupport` を持たない（リアクションで代替）ので、
  /// 従来は **「お気に入り」が 2 行並び上だけ常にグレー**という並びになって
  /// いた。`bookmarkLabel` が Misskey では「お気に入り」なので、同じラベルが
  /// 隣り合う。
  group('概念の無い操作は隠す (#980)', () {
    List<String> labelsOf(List<MenuEntry> entries) => [
      for (final e in entries)
        if (e is MenuActionEntry) e.label,
    ];

    test('Misskey 相当: favorite が無ければ「お気に入り」は 1 行だけになる', () {
      final labels = labelsOf(
        build(
          a: availability(),
          bookmarkLabel: 'お気に入り',
          supportsFavorite: false,
        ),
      );

      expect(
        labels.where((l) => l == 'お気に入り'),
        hasLength(1),
        reason: '同じラベルが 2 行並ぶと、上が常にグレーである理由が読めない',
      );
    });

    test('Mastodon 相当: 両方あれば従来どおり 2 行とも出る', () {
      final labels = labelsOf(build(a: availability()));

      expect(labels, contains('お気に入り'));
      expect(labels, contains('ブックマーク'));
    });

    test('両方無ければ区切り線だけが残らない', () {
      final entries = build(
        a: availability(),
        supportsFavorite: false,
        supportsBookmark: false,
      );

      expect(labelsOf(entries), isNot(contains('お気に入り')));
      expect(labelsOf(entries), isNot(contains('ブックマーク')));
      expect(
        entries.last,
        isNot(isA<MenuGroupSeparator>()),
        reason: '末尾に区切り線が残ると、その下に何かあるように見える',
      );
    });

    /// 隠す判断が **選択ではなくアダプタ** に紐づいていることの確認。
    /// 選択で項目数が動くと、#835 が避けたかった「場所が動いて探しにくい」に
    /// なる。
    test('未選択でも項目数は変わらない（無効で並ぶだけ）', () {
      expect(
        labelsOf(build(a: null)),
        labelsOf(build(a: availability())),
        reason: '選択の有無で項目の数が変わってはいけない',
      );
    });
  });
}
