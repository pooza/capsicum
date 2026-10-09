import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1172: フォーカス中のカラム（`docs/deck-ui-plan.md` 決定済み事項 10）。
///
/// ⚠⚠ **列の変化への追従をここで固定する。**画面に 1 つしか置けないもの（⌘N・
/// 簡易投稿バー・`Ctrl+R`）の宛先なので、**1 フレームでも宛先が無い状態があると
/// 投稿先が決まらない**。
const _me = AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: 'me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> makeContainer() async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('列が空ならフォーカスは無い', () async {
    final container = await makeContainer();
    expect(container.read(deckFocusProvider).columnId, isNull);
  });

  test('初期値は先頭のカラム', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final first = await columns.add(_me, const TimelineTab(TimelineType.home));
    await columns.add(_me, const HashtagTab('delmulin'));

    expect(container.read(deckFocusProvider).columnId, first.id);
  });

  test('カラムを足してもフォーカスは動かない', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final first = await columns.add(_me, const TimelineTab(TimelineType.home));
    // フォーカスを読んで notifier を起こしてから足す（listen が効いている状態）。
    expect(container.read(deckFocusProvider).columnId, first.id);

    await columns.add(_me, const HashtagTab('delmulin'));

    expect(container.read(deckFocusProvider).columnId, first.id);
  });

  test('並べ替えてもフォーカスは同じカラムに残る', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final a = await columns.add(_me, const TimelineTab(TimelineType.home));
    final b = await columns.add(_me, const HashtagTab('delmulin'));
    container.read(deckFocusProvider.notifier).focus(b.id);

    await columns.move(b.id, 0);

    expect(
      container.read(deckFocusProvider).columnId,
      b.id,
      reason: '⚠ 位置ではなく id で持っているので、並べ替えでは移らない',
    );
    expect(container.read(deckColumnsProvider).first.id, b.id);
    expect(a.id, isNot(b.id));
  });

  test('⚠ フォーカス中のカラムを閉じたら右隣へ移る', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final a = await columns.add(_me, const TimelineTab(TimelineType.home));
    final b = await columns.add(_me, const HashtagTab('delmulin'));
    final c = await columns.add(_me, const NotificationsTab());
    container.read(deckFocusProvider.notifier).focus(b.id);

    await columns.remove(b.id);

    expect(container.read(deckFocusProvider).columnId, c.id);
    expect(a.id, isNot(c.id));
  });

  test('⚠ 末尾のカラムを閉じたら左隣へ移る（clamp）', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final a = await columns.add(_me, const TimelineTab(TimelineType.home));
    final b = await columns.add(_me, const HashtagTab('delmulin'));
    container.read(deckFocusProvider.notifier).focus(b.id);

    await columns.remove(b.id);

    expect(container.read(deckFocusProvider).columnId, a.id);
  });

  test('フォーカスしていないカラムを閉じても移らない', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final a = await columns.add(_me, const TimelineTab(TimelineType.home));
    final b = await columns.add(_me, const HashtagTab('delmulin'));
    expect(container.read(deckFocusProvider).columnId, a.id);

    await columns.remove(b.id);

    expect(container.read(deckFocusProvider).columnId, a.id);
  });

  test('最後のカラムを閉じたらフォーカスは無くなる', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final a = await columns.add(_me, const TimelineTab(TimelineType.home));
    expect(container.read(deckFocusProvider).columnId, a.id);

    await columns.remove(a.id);

    expect(container.read(deckFocusProvider).columnId, isNull);
  });

  test('⚠ focus は点滅を要求しない', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    await columns.add(_me, const TimelineTab(TimelineType.home));
    final b = await columns.add(_me, const HashtagTab('delmulin'));
    final before = container.read(deckFocusProvider).blinkToken;

    container.read(deckFocusProvider.notifier).focus(b.id);

    expect(container.read(deckFocusProvider).blinkToken, before);
  });

  test('⚠⚠ focusAndBlink は、既にフォーカス中でも点滅を要求する', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final a = await columns.add(_me, const TimelineTab(TimelineType.home));
    final notifier = container.read(deckFocusProvider.notifier);
    expect(container.read(deckFocusProvider).columnId, a.id);
    final before = container.read(deckFocusProvider).blinkToken;

    notifier.focusAndBlink(a.id);
    expect(container.read(deckFocusProvider).blinkToken, before + 1);

    // 同じカラムから続けて開いた場合。2 回目も鳴らないと「どこに出たか」が
    // 分からなくなる。
    notifier.focusAndBlink(a.id);
    expect(container.read(deckFocusProvider).blinkToken, before + 2);
  });

  test('⚠ 列が動いても点滅の要求カウンタは巻き戻らない', () async {
    final container = await makeContainer();
    final columns = container.read(deckColumnsProvider.notifier);
    final a = await columns.add(_me, const TimelineTab(TimelineType.home));
    final b = await columns.add(_me, const HashtagTab('delmulin'));
    final notifier = container.read(deckFocusProvider.notifier);
    notifier.focusAndBlink(b.id);
    final token = container.read(deckFocusProvider).blinkToken;

    await columns.remove(b.id);

    expect(container.read(deckFocusProvider).columnId, a.id);
    expect(container.read(deckFocusProvider).blinkToken, token);
  });

  test('DeckFocus は値で等しい（watch が無駄に鳴らない前提）', () {
    expect(
      const DeckFocus(columnId: 'a', blinkToken: 2),
      const DeckFocus(columnId: 'a', blinkToken: 2),
    );
    expect(
      const DeckFocus(columnId: 'a', blinkToken: 2),
      isNot(const DeckFocus(columnId: 'a', blinkToken: 3)),
    );
    expect(
      const DeckFocus(columnId: 'a'),
      isNot(const DeckFocus(columnId: 'b')),
    );
  });

  /// #1239: 最後に見ていたカラムを、アプリの終了をまたいで覚える。
  group('最後に見ていたカラムを覚える (#1239)', () {
    test('⚠ フォーカスを移すと保存され、開き直すとそのカラムから始まる', () async {
      final container = await makeContainer();
      final columns = container.read(deckColumnsProvider.notifier);
      await columns.add(_me, const TimelineTab(TimelineType.home));
      final second = await columns.add(_me, const HashtagTab('delmulin'));
      container.read(deckFocusProvider.notifier).focus(second.id);
      await Future<void>.delayed(Duration.zero);

      expect(readDeckLastColumnId(), second.id);

      // アプリを開き直した（同じ保存内容で、別のコンテナ）。
      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      expect(
        reopened.read(deckFocusProvider).columnId,
        second.id,
        reason: '毎回先頭（左端・狭幅では一番上）へ戻っていた',
      );
    });

    test('⚠ 覚えていたカラムが列に居なければ、先頭から始まる', () async {
      final container = await makeContainer();
      final columns = container.read(deckColumnsProvider.notifier);
      final first = await columns.add(
        _me,
        const TimelineTab(TimelineType.home),
      );
      await writeDeckLastColumnId('gone');

      expect(container.read(deckFocusProvider).columnId, first.id);
    });

    test('点滅の要求だけでは書き直さない（同じカラムのまま）', () async {
      final container = await makeContainer();
      final columns = container.read(deckColumnsProvider.notifier);
      final first = await columns.add(
        _me,
        const TimelineTab(TimelineType.home),
      );
      container.read(deckFocusProvider);
      await writeDeckLastColumnId('sentinel');

      container.read(deckFocusProvider.notifier).focusAndBlink(first.id);
      await Future<void>.delayed(Duration.zero);

      expect(readDeckLastColumnId(), 'sentinel');
    });
  });

  /// #1239: 最後に開いていた側（デッキ / タブ UI）で始める。
  group('前回の側で始める (#1239)', () {
    bool decide({
      LastViewMode lastMode = LastViewMode.deck,
      bool hasPendingTab = false,
      String location = '/home',
      bool hasColumns = true,
    }) => shouldStartInDeck(
      lastMode: lastMode,
      hasPendingTab: hasPendingTab,
      location: location,
      hasColumns: hasColumns,
    );

    test('前回デッキで終えていたら、デッキで始める', () {
      expect(decide(), isTrue);
    });

    test('前回タブ UI なら、タブ UI のまま', () {
      expect(decide(lastMode: LastViewMode.tabs), isFalse);
    });

    test('⚠ 通知のタップ等で開くタブが決まっている起動では飛ばない', () {
      expect(decide(hasPendingTab: true), isFalse);
    });

    test('⚠ 別の画面が上に積まれている起動（共有・ディープリンク）では飛ばない', () {
      expect(decide(location: '/compose'), isFalse);
    });

    test('列が空なら開かない', () {
      expect(decide(hasColumns: false), isFalse);
    });

    test('記録の読み書き: 既定はタブ UI', () async {
      await makeContainer();
      expect(readLastViewMode(), LastViewMode.tabs);

      await writeLastViewMode(LastViewMode.deck);
      expect(readLastViewMode(), LastViewMode.deck);

      await writeLastViewMode(LastViewMode.tabs);
      expect(readLastViewMode(), LastViewMode.tabs);
    });
  });
}
