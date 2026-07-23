import 'package:capsicum/src/ui/widget/desktop_menu_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// デスクトップメニュー単一モデル (#841) の中核: 主修飾キーの抽象化と、in-window
/// レンダラのチェック表現・ラベル装飾を検証する。
void main() {
  group('MenuShortcut.resolve', () {
    test('macOS は Cmd(meta)、Windows/Linux は Ctrl で解決する', () {
      const s = MenuShortcut(LogicalKeyboardKey.keyF);
      final mac = s.resolve(useMeta: true);
      expect(mac.meta, isTrue);
      expect(mac.control, isFalse);

      final win = s.resolve(useMeta: false);
      expect(win.meta, isFalse);
      expect(win.control, isTrue);
    });

    test('shift 修飾はそのまま乗る（やり直し ⌘⇧Z 等）', () {
      const s = MenuShortcut(LogicalKeyboardKey.keyZ, shift: true);
      final mac = s.resolve(useMeta: true);
      expect(mac.shift, isTrue);
      expect(mac.meta, isTrue);
      expect(mac.trigger, LogicalKeyboardKey.keyZ);
    });
  });

  group('renderInWindowMenuBar', () {
    testWidgets('サブメニューを開くと項目が並び、バッジがラベルに付く', (tester) async {
      final model = [
        MenuSubmenuEntry(
          label: '移動',
          children: [
            MenuActionEntry(
              label: '検索',
              icon: Icons.search,
              shortcut: const MenuShortcut(LogicalKeyboardKey.keyF),
              onSelected: () {},
            ),
            MenuActionEntry(
              label: 'お知らせ',
              icon: Icons.campaign_outlined,
              badge: 3,
              onSelected: () {},
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: renderInWindowMenuBar(model, const SizedBox.shrink()),
        ),
      );

      expect(find.text('移動'), findsOneWidget);
      await tester.tap(find.text('移動'));
      await tester.pumpAndSettle();

      expect(find.text('検索'), findsOneWidget);
      // badge>0 はラベルに（N）が付く。
      expect(find.text('お知らせ（3）'), findsOneWidget);
    });

    testWidgets('チェック項目は ✓ / 空チェックの先頭アイコンで状態を表す', (tester) async {
      final model = [
        MenuSubmenuEntry(
          label: '表示',
          children: [
            MenuActionEntry(label: '実況を表示', checked: true, onSelected: () {}),
            MenuActionEntry(label: '別のトグル', checked: false, onSelected: () {}),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: renderInWindowMenuBar(model, const SizedBox.shrink()),
        ),
      );

      await tester.tap(find.text('表示'));
      await tester.pumpAndSettle();

      // checked=true は Icons.check、false は Icons.check_box_outline_blank。
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      // in-window はラベルに ✓ を埋め込まない（アイコンで表すため）。
      expect(find.text('実況を表示'), findsOneWidget);
    });

    testWidgets('タップで onSelected が発火する', (tester) async {
      var tapped = false;
      final model = [
        MenuSubmenuEntry(
          label: 'capsicum',
          children: [
            MenuActionEntry(
              label: '設定',
              icon: Icons.settings,
              onSelected: () => tapped = true,
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: renderInWindowMenuBar(model, const SizedBox.shrink()),
        ),
      );

      await tester.tap(find.text('capsicum'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('設定'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });

  group('ネストしたサブメニュー（タブ切替の形）', () {
    testWidgets('in-window は入れ子サブメニューを展開でき、現在項目に ✓ が付く', (tester) async {
      final model = [
        MenuSubmenuEntry(
          label: '表示',
          children: [
            MenuSubmenuEntry(
              label: 'タブ',
              children: [
                MenuActionEntry(label: 'ホーム', checked: true, onSelected: () {}),
                MenuActionEntry(label: '通知', checked: false, onSelected: () {}),
              ],
            ),
          ],
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: renderInWindowMenuBar(model, const SizedBox.shrink()),
        ),
      );
      await tester.tap(find.text('表示'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('タブ'));
      await tester.pumpAndSettle();
      expect(find.text('ホーム'), findsOneWidget);
      expect(find.text('通知'), findsOneWidget);
      // 現在タブ（checked:true）は ✓ アイコン。
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    test('mac は入れ子 MenuSubmenuEntry を PlatformMenu として写す', () {
      final bar =
          renderMacMenuBar([
                MenuSubmenuEntry(
                  label: '表示',
                  children: [
                    MenuSubmenuEntry(
                      label: 'タブ',
                      children: [
                        MenuActionEntry(label: 'ホーム', onSelected: () {}),
                      ],
                    ),
                  ],
                ),
              ], const SizedBox.shrink())
              as PlatformMenuBar;
      final view = bar.menus.single as PlatformMenu;
      final nested = view.menus.single as PlatformMenu;
      expect(nested.label, 'タブ');
      expect(nested.menus.single, isA<PlatformMenuItem>());
    });
  });

  group('collectInWindowShortcuts', () {
    test('globalShortcut:true の項目だけを Ctrl 修飾で集める', () {
      var searched = false;
      final model = [
        MenuSubmenuEntry(
          label: '移動',
          children: [
            MenuActionEntry(
              label: '検索',
              shortcut: const MenuShortcut(LogicalKeyboardKey.keyF),
              globalShortcut: true,
              onSelected: () => searched = true,
            ),
            // globalShortcut:false（編集系相当）は集めない＝二重発火を避ける。
            MenuActionEntry(
              label: 'コピー',
              shortcut: const MenuShortcut(LogicalKeyboardKey.keyC),
              onSelected: () {},
            ),
            // shortcut 無しは対象外。
            MenuActionEntry(label: '通知', onSelected: () {}),
          ],
        ),
      ];

      final bindings = collectInWindowShortcuts(model);
      expect(bindings, hasLength(1));
      final activator = bindings.keys.single as SingleActivator;
      expect(activator.trigger, LogicalKeyboardKey.keyF);
      expect(activator.control, isTrue);
      expect(activator.meta, isFalse);
      // 束ねた callback が元の onSelected を呼ぶ。
      bindings.values.single();
      expect(searched, isTrue);
    });

    testWidgets('in-window レンダラは globalShortcut があると CallbackShortcuts で包む', (
      tester,
    ) async {
      final model = [
        MenuSubmenuEntry(
          label: '移動',
          children: [
            MenuActionEntry(
              label: '検索',
              shortcut: const MenuShortcut(LogicalKeyboardKey.keyF),
              globalShortcut: true,
              onSelected: () {},
            ),
          ],
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: renderInWindowMenuBar(model, const SizedBox.shrink()),
        ),
      );
      expect(find.byType(CallbackShortcuts), findsOneWidget);
    });
  });

  group('renderMacMenuBar', () {
    // device なしで native メニュー経路の構造を検証する（macOS は run 確認が
    // しづらいため、モデル→PlatformMenu の変換をここで固める）。
    PlatformMenuBar bar(List<MenuSubmenuEntry> model) =>
        renderMacMenuBar(model, const SizedBox.shrink()) as PlatformMenuBar;

    test('MenuGroupSeparator で PlatformMenuItemGroup に分割する', () {
      final b = bar([
        MenuSubmenuEntry(
          label: 'アカウント',
          children: [
            MenuActionEntry(label: 'プロフィール', onSelected: () {}),
            const MenuGroupSeparator(),
            MenuActionEntry(label: 'アカウントを追加', onSelected: () {}),
            MenuActionEntry(label: 'ログアウト', onSelected: () {}),
          ],
        ),
      ]);
      final menu = b.menus.single as PlatformMenu;
      // 2 グループ（[プロフィール] と [追加, ログアウト]）に分かれる。
      final groups = menu.menus.whereType<PlatformMenuItemGroup>().toList();
      expect(groups, hasLength(2));
      expect(groups[0].members, hasLength(1));
      expect(groups[1].members, hasLength(2));
    });

    test('区切りが無ければフラットに並べる', () {
      final b = bar([
        MenuSubmenuEntry(
          label: '編集',
          children: [
            MenuActionEntry(label: 'コピー', onSelected: () {}),
            MenuActionEntry(label: 'ペースト', onSelected: () {}),
          ],
        ),
      ]);
      final menu = b.menus.single as PlatformMenu;
      expect(menu.menus.whereType<PlatformMenuItemGroup>(), isEmpty);
      expect(menu.menus.whereType<PlatformMenuItem>(), hasLength(2));
    });

    test('checked=true はラベル末尾に ✓ を埋め込む（mac はチェック API 無し）', () {
      final b = bar([
        MenuSubmenuEntry(
          label: '表示',
          children: [
            MenuActionEntry(label: '実況を表示', checked: true, onSelected: () {}),
          ],
        ),
      ]);
      final menu = b.menus.single as PlatformMenu;
      final item = menu.menus.single;
      expect(item.label, '実況を表示 ✓');
    });

    test('ショートカットは Cmd(meta) で解決する', () {
      final b = bar([
        MenuSubmenuEntry(
          label: '移動',
          children: [
            MenuActionEntry(
              label: '検索',
              shortcut: const MenuShortcut(LogicalKeyboardKey.keyF),
              onSelected: () {},
            ),
          ],
        ),
      ]);
      final menu = b.menus.single as PlatformMenu;
      final item = menu.menus.single;
      final shortcut = item.shortcut as SingleActivator;
      expect(shortcut.meta, isTrue);
      expect(shortcut.control, isFalse);
      expect(shortcut.trigger, LogicalKeyboardKey.keyF);
    });
  });
}
