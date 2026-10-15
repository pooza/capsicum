import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/word_mute_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1290: Misskey のワードミュートの画面。
class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, WordMuteSupport {
  _FakeAdapter({required this.soft, required this.hard});

  List<Object> soft;
  List<Object> hard;
  final saves = <({List<Object>? soft, List<Object>? hard})>[];

  @override
  String get host => 'misskey.example';

  @override
  Future<({List<Object> soft, List<Object> hard})> getWordMutes() async =>
      (soft: soft, hard: hard);

  @override
  Future<void> setWordMutes({List<Object>? soft, List<Object>? hard}) async {
    saves.add((soft: soft, hard: hard));
  }
}

Future<void> _pump(WidgetTester tester, _FakeAdapter adapter) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [currentAdapterProvider.overrideWithValue(adapter)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const WordMuteScreen()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('読み込んだ一覧を 1 行 1 条件で出す', (tester) async {
    final adapter = _FakeAdapter(
      soft: const [
        ['ダイ', 'ポップ'],
        '/アバン/i',
      ],
      hard: const ['/ハドラー/'],
    );
    await _pump(tester, adapter);

    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields[0].controller!.text, 'ダイ ポップ\n/アバン/i');
    expect(fields[1].controller!.text, '/ハドラー/');
  });

  testWidgets('⚠⚠ 保存は変えた段だけを送る（全置換なので、送ると消える）', (tester) async {
    final adapter = _FakeAdapter(
      soft: const [
        ['ダイ'],
      ],
      hard: const ['/ハドラー/'],
    );
    await _pump(tester, adapter);

    await tester.enterText(find.byType(TextField).first, 'ダイ\nポップ マァム');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final save = adapter.saves.single;
    expect(save.soft, [
      ['ダイ'],
      ['ポップ', 'マァム'],
    ]);
    expect(save.hard, isNull);
    expect(find.byType(WordMuteScreen), findsNothing, reason: '保存したら閉じる');
  });

  testWidgets('⚠ 読めない正規表現は何行目かを出し、送らない', (tester) async {
    final adapter = _FakeAdapter(soft: const [], hard: const []);
    await _pump(tester, adapter);

    await tester.enterText(find.byType(TextField).last, 'ダイ\n/(/');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(adapter.saves, isEmpty);
    expect(find.text('ハードワードミュートの 2 行目の正規表現が読めません'), findsOneWidget);
  });
}
