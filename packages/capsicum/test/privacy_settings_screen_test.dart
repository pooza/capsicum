import 'dart:io';

import 'package:capsicum/src/ui/screen/privacy_settings_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1375: プライバシーとつながりやすさの画面。
const _mastodon = PrivacySettings(
  locked: false,
  discoverable: true,
  indexable: true,
  hideCollections: false,
  searchEngineHidden: true,
  searchEngineEditable: false,
);

const _misskey = PrivacySettings(
  locked: true,
  discoverable: false,
  searchEngineHidden: false,
  searchEngineEditable: true,
  autoAcceptFollowed: true,
  publicReactions: false,
  followingVisibility: FollowListVisibility.followers,
  followersVisibility: FollowListVisibility.public,
  hideOnlineStatus: false,
  preventAiLearning: true,
  requireSigninToViewContents: false,
);

void main() {
  late List<PrivacySettings> changes;
  late int webOpened;

  Future<void> pump(WidgetTester tester, PrivacySettings settings) async {
    changes = [];
    webOpened = 0;
    // ⚠ ListView は画面外の行を組まないので、全部の行が載る高さにする。
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ListView(
              children: privacySettingsTiles(
                context,
                settings,
                onChanged: changes.add,
                onOpenWebSettings: () => webOpened++,
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('Mastodon', () {
    testWidgets('つながりやすさ・被検索性・プライバシーの節で出す', (tester) async {
      await pump(tester, _mastodon);

      expect(find.text('つながりやすさ'), findsOneWidget);
      expect(find.text('被検索性'), findsOneWidget);
      expect(find.text('プライバシー'), findsOneWidget);
      expect(find.text('フォローを承認制にする'), findsOneWidget);
      expect(find.text('おすすめ・発見に載せる'), findsOneWidget);
      expect(find.text('公開投稿を検索できるようにする'), findsOneWidget);
      expect(find.text('フォロー・フォロワーを隠す'), findsOneWidget);
      // Misskey だけの項目は出さない。
      expect(find.text('フォロー中の相手は自動で承認する'), findsNothing);
      expect(find.text('AI の学習を拒否する'), findsNothing);
    });

    testWidgets('⚠ 検索エンジンは状態を出して Web へ誘導する（スイッチにしない）', (tester) async {
      await pump(tester, _mastodon);

      final tile = find.widgetWithText(ListTile, '検索エンジンからアクセスできるようにする');
      expect(tile, findsOneWidget);
      expect(find.textContaining('いまは「しない」です'), findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.byType(Switch)),
        findsNothing,
      );

      await tester.tap(tile);
      expect(webOpened, 1);
      expect(changes, isEmpty);
    });

    testWidgets('トグルは変えた項目だけを渡す', (tester) async {
      await pump(tester, _mastodon);

      await tester.tap(find.text('公開投稿を検索できるようにする'));
      expect(changes.single.indexable, isFalse);
      expect(changes.single.locked, isNull);
      expect(changes.single.discoverable, isNull);
    });
  });

  group('Misskey', () {
    testWidgets('Misskey の項目を出し、Mastodon だけの項目は出さない', (tester) async {
      await pump(tester, _misskey);

      for (final title in [
        'フォローを承認制にする',
        'フォロー中の相手は自動で承認する',
        'おすすめ・発見に載せる',
        '検索エンジンに載せる',
        'フォロー中の一覧の公開範囲',
        'フォロワーの一覧の公開範囲',
        'リアクションを公開する',
        'オンライン状態を隠す',
        'AI の学習を拒否する',
        'ログインしていない人には見せない',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('公開投稿を検索できるようにする'), findsNothing);
      expect(find.text('フォロー・フォロワーを隠す'), findsNothing);
    });

    testWidgets('⚠ 検索エンジン（noCrawle）は「載せる」で聞くので反転して渡す', (tester) async {
      await pump(tester, _misskey);

      final tile = find.widgetWithText(SwitchListTile, '検索エンジンに載せる');
      expect(
        tester.widget<SwitchListTile>(tile).value,
        isTrue,
        reason: 'noCrawle が false なら「載せる」',
      );

      await tester.tap(tile);
      expect(changes.single.searchEngineHidden, isTrue);
    });

    testWidgets('一覧の公開範囲を選ぶと、その項目だけを渡す', (tester) async {
      await pump(tester, _misskey);

      await tester.tap(find.text('フォロワーのみ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自分のみ').last);
      await tester.pumpAndSettle();

      expect(changes.single.followingVisibility, FollowListVisibility.private);
      expect(changes.single.followersVisibility, isNull);
    });
  });

  testWidgets('⚠ 項目が 1 つも無い節は、見出しごと出さない', (tester) async {
    await pump(tester, const PrivacySettings(locked: false));

    expect(find.text('つながりやすさ'), findsOneWidget);
    expect(find.text('被検索性'), findsNothing);
    expect(find.text('プライバシー'), findsNothing);
  });

  // ⚠⚠ プロフィール編集は承認制・おすすめへの掲載を送らない（#1375）。送ると、
  // プロフィールを保存するたびに、この画面で変えた値を開いたときの値で上書きする。
  group('プロフィール編集から送らない', () {
    const path = 'lib/src/ui/screen/profile_edit_screen.dart';
    final sendsPrivacy = RegExp(r'\b(locked|discoverable)\s*:');

    List<String> offenders(String source) => [
      for (final m in sendsPrivacy.allMatches(maskComments(source))) m[0]!,
    ];

    test('updateProfile を呼んでいて、locked / discoverable を渡していない', () {
      final source = File(path).readAsStringSync();
      expect(source, contains('.updateProfile('), reason: '走査の対象が実在する');
      expect(offenders(source), isEmpty);
    });

    test('判定（合成ソース）', () {
      expect(offenders('updateProfile(locked: _locked)'), isNotEmpty);
      expect(offenders('updateProfile(\n  discoverable: x,\n)'), isNotEmpty);
      expect(offenders('// locked: は送らない'), isEmpty, reason: 'コメントは数えない');
      expect(offenders('updateProfile(displayName: n)'), isEmpty);
    });
  });
}
