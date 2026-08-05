import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/flash/flash_runtime.dart';
import 'package:capsicum/src/ui/screen/flash_view_screen.dart';
import 'package:capsicum/src/ui/widget/emoji_text.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
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

  /// 設定すると [likeFlash] がこれを投げる（非べき等コードの吸収検証・#873）。
  Object? likeError;

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
  Future<void> likeFlash(String flashId) async {
    likeCalls++;
    if (likeError != null) throw likeError!;
  }

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

    testWidgets('新しい AiScript 宣言の degrade は両方のバージョンを事実として出す (#934)', (
      tester,
    ) async {
      // 「正しく動作しない可能性があります」のような反証不可能な文言に戻さない。
      // 予測ではなく数値（申告値と搭載版）と、1.0 で何が変わったかを出す。
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('''
          /// @1.0.0
          Ui:render([Ui:C:text({ text: "新しい版" }, "t")])
        '''),
      );

      expect(find.textContaining('1.0.0 以降向け'), findsOneWidget);
      expect(
        find.textContaining(FlashRuntime.engineLangVersion),
        findsOneWidget,
      );
      // degrade は失敗ではないので、評価せず逃がしたことが分かる導線を出す。
      expect(find.text('ブラウザで開く'), findsOneWidget);
      expect(find.text('このまま実行する'), findsOneWidget);
      // 再度 degrade するだけの「再試行」は出さない。
      expect(find.text('再試行'), findsNothing);
      // 評価していないので描画ツリーは出ない。
      expect(find.text('新しい版'), findsNothing);
    });

    /// #935: 「Web 版と出目が違う」の手掛かりを、バージョン警告とは独立に置く。
    ///
    /// 眼目は **掲出範囲**。バージョン警告 (#934) は degrade を踏んだ Play に
    /// しか出ないが、出目差はバージョンと無関係に起きるので、警告の出ない
    /// Play にも手掛かりが要る。一方で乱数と無縁な Play に出すと雑音になる。
    testWidgets('乱数を使う Play には、警告が無くても注記を畳んで出す (#935)', (tester) async {
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('''
          let n = Math:rnd(0 10)
          Ui:render([Ui:C:text({ text: `{n}` }, "t")])
        '''),
      );

      expect(find.textContaining('乱数について'), findsOneWidget);
      // 畳んである（本文は開くまで出さない）。
      expect(find.textContaining('実行のたびに結果が変わります'), findsNothing);

      await tester.tap(find.textContaining('乱数について'));
      await tester.pumpAndSettle();

      expect(find.textContaining('実行のたびに結果が変わります'), findsOneWidget);
      expect(find.textContaining('Web版と異なる結果'), findsOneWidget);
    });

    testWidgets('乱数を使わない Play には出さない (#935)', (tester) async {
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('Ui:render([Ui:C:text({ text: "ふつう" }, "t")])'),
      );

      expect(find.textContaining('乱数について'), findsNothing);
    });

    /// **同じブロックに並べない**という #935 の制約。並ぶと「バージョンのせい」
    /// に吸収され、注記の目的（バージョンとは無関係だと伝えること）が壊れる。
    testWidgets('バージョン警告が出ている間は乱数注記を出さない (#935)', (tester) async {
      final adapter = _FakeAdapter();
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('''
          /// @1.0.0
          let n = Math:rnd(0 10)
          Ui:render([Ui:C:text({ text: "新しい版" }, "t")])
        '''),
      );

      expect(find.textContaining('1.0.0 以降向け'), findsOneWidget);
      expect(find.textContaining('乱数について'), findsNothing);
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
            emojis: {
              'dai_smile': 'https://misskey.example/emoji/dai_smile.webp',
            },
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

    testWidgets('ALREADY_LIKED はいいね成功として吸収し巻き戻さない (#873)', (tester) async {
      // stale な isLiked=false でタップ → サーバーは既にいいね済み。
      // 楽観状態（liked）を確定させ、favorite_border に戻さない。
      final adapter = _FakeAdapter()
        ..likeError = DioException(
          requestOptions: RequestOptions(path: '/api/flash/like'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/flash/like'),
            statusCode: 400,
            data: {
              'error': {'code': 'ALREADY_LIKED'},
            },
          ),
        );
      await _pump(
        tester,
        adapter,
        initialFlash: _flash('Ui:render([Ui:C:text({ text: "x" }, "t")])'),
      );

      await tester.tap(find.byIcon(Icons.favorite_border));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(find.text('4'), findsOneWidget);
    });
  });
}
