import 'dart:io';

import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/widget/deck_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1174: デッキの画面全体に 1 枚、背景画像を敷く。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// カラムの中身に当たる `Scaffold` を置いて組む。
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(scaffoldBackgroundColor: Colors.white),
          home: const DeckBackground(
            child: Scaffold(key: Key('column'), body: SizedBox()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Color columnColor(WidgetTester tester) => Theme.of(
    tester.element(find.byKey(const Key('column'))),
  ).scaffoldBackgroundColor;

  testWidgets('画像が無ければ敷かず、カラムの地色も変えない', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await pump(tester);

    expect(columnColor(tester), Colors.white);
    expect(
      find.descendant(
        of: find.byType(DeckBackground),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
  });

  testWidgets('⚠⚠ 画像があれば敷き、カラムを透かす', (tester) async {
    final image = await tester.runAsync(() async {
      final file = File(
        '${(await Directory.systemTemp.createTemp()).path}/bg.png',
      );
      await file.writeAsBytes(const [0]);
      return file;
    });
    SharedPreferences.setMockInitialValues({
      'background_image_path_$deckBackgroundStorageKey': image!.path,
    });

    await tester.runAsync(() async {
      await pump(tester);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(columnColor(tester), Colors.transparent);
    final decoration =
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byType(DeckBackground),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.image!.fit, BoxFit.cover);
    expect(decoration.image!.opacity, defaultBackgroundOpacity);
  });

  test('⚠ アカウント用の旧い全体設定を、デッキへ持ち込まない', () async {
    final file = File(
      '${(await Directory.systemTemp.createTemp()).path}/legacy.png',
    );
    await file.writeAsBytes(const [0]);
    SharedPreferences.setMockInitialValues({
      'background_image_path': file.path,
      'background_opacity': 0.4,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(backgroundImageProvider(deckBackgroundStorageKey));
    container.read(backgroundOpacityProvider(deckBackgroundStorageKey));
    container.read(backgroundImageProvider('account'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container.read(backgroundImageProvider(deckBackgroundStorageKey)),
      isNull,
    );
    expect(
      container.read(backgroundOpacityProvider(deckBackgroundStorageKey)),
      defaultBackgroundOpacity,
    );
    expect(
      container.read(backgroundImageProvider('account')),
      file.path,
      reason: '前提: アカウントには持ち込まれる',
    );
  });

  test('デッキ画面が敷いている', () {
    final source = File(
      'lib/src/ui/screen/deck_screen.dart',
    ).readAsStringSync();

    expect(source, contains('DeckBackground('));
  });
}
