import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/flash_view_screen.dart';
import 'package:capsicum/src/ui/widget/emoji_text.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Flash（UI 表記は Play）詳細画面 (#830)。
///
/// AiScript をネイティブ実行して `Ui:` の描画ツリーを出す経路と、実行できない
/// ときにブラウザへ degrade する経路を固定する。

const _author = User(id: 'u1', username: 'alice', displayName: 'アリス');

Flash _flash(
  String script, {
  String summary = '今日の運勢',
  User author = _author,
}) => Flash(
  id: 'flash1',
  title: 'ダイ大おみくじ',
  summary: summary,
  script: script,
  author: author,
  createdAt: DateTime(2026, 7, 1),
  updatedAt: DateTime(2026, 7, 1),
  likedCount: 3,
);

class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, FlashSupport, CustomEmojiSupport {
  _FakeAdapter({this.showResult});

  final Flash? showResult;
  int likeCalls = 0;
  int unlikeCalls = 0;

  @override
  String get host => 'misskey.example';

  @override
  Future<List<CustomEmoji>> getEmojis() async => const [
    CustomEmoji(shortcode: 'dai_smile', url: '', category: 'ダイ大'),
  ];

  @override
  Future<List<String>> getEmojiPalette() async => const [];

  @override
  Future<Flash> getFlashById(String flashId) async {
    final result = showResult;
    if (result == null) throw StateError('not found');
    return result;
  }

  @override
  Future<void> likeFlash(String flashId) async => likeCalls++;

  @override
  Future<void> unlikeFlash(String flashId) async => unlikeCalls++;
}

Future<void> _pump(
  WidgetTester tester,
  _FakeAdapter adapter, {
  Flash? initialFlash,
  String? flashId,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [currentAdapterProvider.overrideWithValue(adapter)],
      child: MaterialApp(
        home: FlashViewScreen(initialFlash: initialFlash, flashId: flashId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('FlashViewScreen (#830)', () {
    testWidgets('スクリプトを実行して Ui: の描画ツリーを出す', (tester) async {
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('''
          Ui:render([
            Ui:C:container({
              children: [Ui:C:text({ text: "大吉" }, "result")]
            }, "box")
          ])
        '''),
      );

      expect(find.text('ダイ大おみくじ'), findsOneWidget);
      expect(find.text('今日の運勢'), findsOneWidget);
      expect(find.text('大吉'), findsOneWidget);
    });

    testWidgets('CUSTOM_EMOJIS がロードされてからスクリプトに渡る', (tester) async {
      // 空で走らせると絵文字ガチャ系の結果が変わってしまうため、
      // customEmojisProvider の解決を待ってから実行すること。
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('''
          let names = CUSTOM_EMOJIS.map(@(e) { e.name })
          Ui:render([Ui:C:text({ text: names.join(",") }, "t")])
        '''),
      );

      expect(find.text('dai_smile'), findsOneWidget);
    });

    testWidgets('未対応の Ui: を使う Play はブラウザへ degrade できる', (tester) async {
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('Ui:render([Ui:C:canvas({}, "c")])'),
      );

      expect(find.textContaining('未対応'), findsOneWidget);
      expect(find.text('Ui:C:canvas'), findsNothing);
      expect(find.textContaining('Ui:C:canvas'), findsOneWidget);
      // 行き止まりにしない。
      expect(find.text('ブラウザで開く'), findsOneWidget);
      expect(find.text('再試行'), findsOneWidget);
    });

    testWidgets('script が空の一覧エントリは show で取り直す', (tester) async {
      final adapter = _FakeAdapter(
        showResult: _flash('Ui:render([Ui:C:text({ text: "取得済" }, "t")])'),
      );
      await _pump(tester, adapter, initialFlash: _flash(''));

      expect(find.text('取得済'), findsOneWidget);
    });

    testWidgets('取得に失敗したら再試行を出す（エラー詳細は出さない）', (tester) async {
      // Misskey の URL には ?i=<accessToken> が載るため、snapshot.error を
      // 画面に出してはいけない (#460 同型)。
      final adapter = _FakeAdapter();
      await _pump(tester, adapter, flashId: 'missing');

      expect(find.text('Play の読み込みに失敗しました'), findsOneWidget);
      expect(find.textContaining('StateError'), findsNothing);
    });

    testWidgets('作者の表示名はカスタム絵文字対応で描画する', (tester) async {
      // 表示名に :emoji: が入りうるので、素の Text ではなく他画面と同じ
      // EmojiText を通す。
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash(
          'Ui:render([Ui:C:text({ text: "x" }, "t")])',
          author: const User(
            id: 'u1',
            username: 'alice',
            displayName: ':dai_smile: アリス',
            emojis: {'dai_smile': 'https://misskey.example/emoji/dai_smile.webp'},
          ),
        ),
      );

      final names = tester.widgetList<EmojiText>(find.byType(EmojiText));
      expect(names.any((w) => w.emojis.containsKey('dai_smile')), isTrue);
    });

    testWidgets('説明文は本文と同じレンダリング（素の Text ではない）', (tester) async {
      // 説明文に acct / URL / ハッシュタグ / 絵文字が入りうる。ContentRenderer を
      // 通すので Text.rich（data == null）になり、生 URL やタグがリンク化される。
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash(
          'Ui:render([Ui:C:text({ text: "x" }, "t")])',
          summary: '遊んでみた #さんぽ https://example.com',
        ),
      );

      final summary = tester.widget<Text>(find.textContaining('さんぽ'));
      expect(summary.data, isNull);
      expect(summary.textSpan, isNotNull);
    });

    testWidgets('いいねは楽観更新し、サーバーへ送る', (tester) async {
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('Ui:render([Ui:C:text({ text: "x" }, "t")])'),
      );

      expect(find.text('3'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.favorite_border));
      await tester.pumpAndSettle();

      expect(find.text('4'), findsOneWidget);
      expect(adapter.likeCalls, 1);
    });
  });
}
