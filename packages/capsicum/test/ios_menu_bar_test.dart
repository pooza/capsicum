import 'package:capsicum/src/ui/widget/desktop_menu_model.dart';
import 'package:capsicum/src/ui/widget/ios_menu_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1268: iPad のメニューバー（iPadOS 26〜）へ、デスクトップと同じモデルを載せる。
///
/// ⚠ Flutter の `PlatformMenuBar` は iOS で動かないので、モデルを JSON にして
/// ネイティブ（`AppDelegate.swift` の `MenuBarPlugin`）へ渡す。ここではその
/// 変換を見る。
void main() {
  void noop() {}

  group('置き場所', () {
    test('システムのメニューと重なるものは、その中へ入れるか任せる', () {
      expect(iosMenuPlacement('capsicum'), IosMenuPlacement.application);
      expect(iosMenuPlacement('ファイル'), IosMenuPlacement.file);
      expect(iosMenuPlacement('表示'), IosMenuPlacement.view);
      expect(
        iosMenuPlacement('編集'),
        IosMenuPlacement.skip,
        reason: '⚠ コピー・ペーストを二重に並べると同じキーが 2 つになる',
      );
      expect(iosMenuPlacement('ウインドウ'), IosMenuPlacement.skip);
    });

    test('capsicum 独自のメニューは Edit の後ろに新しく入れる', () {
      expect(iosMenuPlacement('移動'), IosMenuPlacement.afterEdit);
      expect(iosMenuPlacement('アカウント'), IosMenuPlacement.afterEdit);
    });
  });

  group('iosMenuPayload', () {
    test('項目・区切り・入れ子を渡し、選択は id で呼び返せる', () {
      final calls = <String>[];
      final callbacks = <int, VoidCallback>{};
      final payload = iosMenuPayload([
        MenuSubmenuEntry(
          label: '移動',
          children: [
            MenuActionEntry(
              label: '新規投稿',
              shortcut: const MenuShortcut(LogicalKeyboardKey.keyN),
              onSelected: () => calls.add('compose'),
            ),
            const MenuGroupSeparator(),
            MenuSubmenuEntry(
              label: 'カラム',
              children: [
                MenuActionEntry(
                  label: '通知',
                  checked: true,
                  onSelected: () => calls.add('column'),
                ),
              ],
            ),
          ],
        ),
      ], callbacks);

      expect(payload, hasLength(1));
      final menu = payload.single;
      expect(menu['placement'], 'afterEdit');
      expect(menu['title'], '移動');
      final children = menu['children']! as List;
      final compose = children[0] as Map;
      expect(compose['title'], '新規投稿');
      expect(compose['input'], 'n');
      expect(compose['shift'], isFalse);
      expect(compose['enabled'], isTrue);
      expect((children[1] as Map)['type'], 'separator');
      final column = ((children[2] as Map)['children'] as List).single as Map;
      expect(column['checked'], isTrue);

      callbacks[compose['id']! as int]!();
      callbacks[column['id']! as int]!();
      expect(calls, ['compose', 'column']);
    });

    test('⚠ 編集・ウインドウと OS 提供の項目は送らない（iPad のシステムのメニューが持つ）', () {
      final payload = iosMenuPayload([
        MenuSubmenuEntry(
          label: 'capsicum',
          children: [
            const MenuActionEntry(label: 'capsicum について', onSelected: _noop),
            const MenuProvidedEntry(macType: PlatformProvidedMenuItemType.quit),
          ],
        ),
        const MenuSubmenuEntry(
          label: '編集',
          children: [MenuActionEntry(label: 'コピー', onSelected: _noop)],
        ),
        const MenuSubmenuEntry(
          label: 'ウインドウ',
          children: [
            MenuProvidedEntry(
              macType: PlatformProvidedMenuItemType.minimizeWindow,
            ),
          ],
        ),
      ], {});

      expect(payload.map((m) => m['title']), ['capsicum']);
      expect(payload.single['children'], hasLength(1), reason: '終了は落とす');
    });

    test('押せない項目は無効、未読の数はラベルに付ける、Shift も渡す', () {
      final payload = iosMenuPayload([
        MenuSubmenuEntry(
          label: '移動',
          children: [
            const MenuActionEntry(label: '押せない'),
            MenuActionEntry(label: 'お知らせ', badge: 3, onSelected: noop),
            MenuActionEntry(
              label: 'ナウプレで新規投稿',
              shortcut: const MenuShortcut(
                LogicalKeyboardKey.keyN,
                shift: true,
              ),
              onSelected: noop,
            ),
          ],
        ),
      ], {});

      final children = payload.single['children']! as List;
      expect((children[0] as Map)['enabled'], isFalse);
      expect((children[1] as Map)['title'], 'お知らせ（3）');
      expect((children[2] as Map)['input'], 'n');
      expect((children[2] as Map)['shift'], isTrue);
    });
  });

  group('IosMenuBridge（#1332 のレビュー）', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('capsicum/menu_bar');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<Map<Object?, Object?>> sent;

    setUp(() {
      sent = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setMenus') {
          sent.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    List<MenuSubmenuEntry> model(String label, VoidCallback onSelected) => [
      MenuSubmenuEntry(
        label: '移動',
        children: [MenuActionEntry(label: label, onSelected: onSelected)],
      ),
    ];

    Future<void> select(int generation, int id) =>
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('menuSelected', {'generation': generation, 'id': id}),
          ),
          (_) {},
        );

    test('⚠⚠ 構造が同じなら送り直さず、コールバックだけ差し替える', () async {
      final calls = <String>[];
      IosMenuBridge.publish(model('新規投稿', () => calls.add('old')));
      // build のたびに作り直されたラムダ（項目の == では別物）。
      IosMenuBridge.publish(model('新規投稿', () => calls.add('new')));
      await Future<void>.delayed(Duration.zero);

      expect(sent, hasLength(1), reason: '構造が同じなら送らない');
      await select(sent.single['generation']! as int, 1);
      expect(calls, ['new'], reason: '選択は差し替えた新しいコールバックに届く');
    });

    test('⚠⚠ 古い世代のメニューから届いた選択は捨てる', () async {
      final calls = <String>[];
      IosMenuBridge.publish(model('A', () => calls.add('A')));
      await Future<void>.delayed(Duration.zero);
      final first = sent.last['generation']! as int;
      IosMenuBridge.publish(model('B', () => calls.add('B')));
      await Future<void>.delayed(Duration.zero);
      final second = sent.last['generation']! as int;
      expect(second, greaterThan(first));

      await select(first, 1); // 組み直す前の古いメニューから
      await select(second, 1);
      expect(calls, ['B']);
    });
  });

  test('キーの文字は小文字の 1 文字（記号もそのまま）', () {
    expect(iosKeyInput(LogicalKeyboardKey.keyN), 'n');
    expect(iosKeyInput(LogicalKeyboardKey.comma), ',');
    expect(iosKeyInput(LogicalKeyboardKey.bracketLeft), '[');
    expect(iosKeyInput(LogicalKeyboardKey.digit1), '1');
    expect(iosKeyInput(LogicalKeyboardKey.enter), isNull);
  });
}

void _noop() {}
