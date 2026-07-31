import 'package:capsicum/src/ui/widget/desktop_menu_model.dart';
import 'package:capsicum/src/ui/widget/screen_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #835: デスクトップメニューを表示中の画面に連動させる枠組み。
///
/// 項目そのものは画面ごとに後から足していくので、ここでは枠組みの性質
/// （最前面の宣言だけが出る・画面を離れたら消える・固定メニューの並びを
/// 壊さない）を固める。
MenuSubmenuEntry _submenu(String label) =>
    MenuSubmenuEntry(label: label, children: const []);

List<MenuSubmenuEntry> _baseModel() => [
  _submenu('capsicum'),
  _submenu('編集'),
  _submenu('移動'),
  _submenu('表示'),
  _submenu('ウインドウ'),
];

ScreenMenuContribution _contribution(String label) => ScreenMenuContribution(
  label: label,
  entries: [MenuActionEntry(label: '$label の操作', onSelected: () {})],
);

void main() {
  group('withScreenMenu', () {
    test('宣言が無ければ固定メニューのまま', () {
      final model = _baseModel();
      expect(withScreenMenu(model, null), same(model));
    });

    test('項目が空の宣言は差し込まない', () {
      final model = _baseModel();
      final empty = const ScreenMenuContribution(label: 'メディア', entries: []);
      expect(withScreenMenu(model, empty), same(model));
    });

    test('「表示」の後・「ウインドウ」の前に入る', () {
      final result = withScreenMenu(_baseModel(), _contribution('メディア'));

      expect(result.map((m) => m.label), [
        'capsicum',
        '編集',
        '移動',
        '表示',
        'メディア',
        'ウインドウ',
      ]);
    });

    test('「ウインドウ」が無いモデルでは末尾に足す', () {
      final model = [_submenu('capsicum'), _submenu('表示')];

      final result = withScreenMenu(model, _contribution('メディア'));

      expect(result.map((m) => m.label), ['capsicum', '表示', 'メディア']);
    });
  });

  group('ScreenMenu', () {
    testWidgets('マウント中だけ宣言が有効になる', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      Widget app(bool showScreen) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: showScreen
              ? ScreenMenu(
                  label: 'メディア',
                  entries: [MenuActionEntry(label: '保存', onSelected: () {})],
                  child: const SizedBox(),
                )
              : const SizedBox(),
        ),
      );

      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(container.read(activeScreenMenuProvider)?.label, 'メディア');

      // 画面を離れたら取り下げられる。
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(container.read(activeScreenMenuProvider), isNull);
    });

    testWidgets('重なったときは最前面の宣言が出て、閉じると下の画面へ戻る', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      Widget app(bool showTop) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ScreenMenu(
            label: 'スレッド',
            entries: [MenuActionEntry(label: '先頭へ', onSelected: () {})],
            child: showTop
                ? ScreenMenu(
                    label: 'メディア',
                    entries: [MenuActionEntry(label: '保存', onSelected: () {})],
                    child: const SizedBox(),
                  )
                : const SizedBox(),
          ),
        ),
      );

      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(container.read(activeScreenMenuProvider)?.label, 'メディア');

      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(container.read(activeScreenMenuProvider)?.label, 'スレッド');

      // 取り下げはフレーム後に走るので、木を畳んでから最後まで流す
      // （残った宣言の取り下げが pending timer として残らないように）。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(container.read(activeScreenMenuProvider), isNull);
    });

    /// 投稿画面のように 1 文字打つたびに再ビルドされる画面が採用するため、
    /// 「中身が同じ再ビルド」でメニューバーを作り直さないことを固める (#835)。
    testWidgets('中身が同じ再ビルドでは宣言を作り直さない', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var updates = 0;
      container.listen(activeScreenMenuProvider, (_, _) => updates++);

      // 画面側と同じく、ビルドのたびに新しいリストを組み直す。
      void onSave() {}
      Widget app(bool checked) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ScreenMenu(
            label: 'メディア',
            entries: [
              MenuActionEntry(
                label: '保存',
                checked: checked,
                onSelected: onSave,
              ),
            ],
            child: const SizedBox(),
          ),
        ),
      );

      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(updates, 1, reason: '初回の登録');

      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(updates, 1, reason: '中身が同じなら登録し直さない');

      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(updates, 2, reason: 'チェック状態が変わったら反映する');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });
}
