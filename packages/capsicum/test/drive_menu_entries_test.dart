import 'package:capsicum/src/ui/screen/drive_manager_screen.dart';
import 'package:capsicum/src/ui/widget/desktop_menu_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// #939: ドライブ画面のデスクトップメニュー項目。
///
/// 眼目は #835 で決めた「**出し分けの条件は画面のツールバー / メニュー側と
/// 同一にする。使えない操作をメニューにだけ見せない**」。この画面は選択モードで
/// AppBar の actions が丸ごと入れ替わるので、メニュー側も同じ条件で有効・無効が
/// 切り替わらないと、押しても何も起きない項目が残る。
void main() {
  List<MenuEntry> build({
    bool canGoUp = false,
    bool selectionMode = false,
    bool hasSelection = false,
    List<String>? log,
  }) => buildDriveMenuEntries(
    canGoUp: canGoUp,
    selectionMode: selectionMode,
    hasSelection: hasSelection,
    onGoUp: () => log?.add('up'),
    onRefresh: () => log?.add('refresh'),
    onCreateFolder: () => log?.add('createFolder'),
    onEnterSelectionMode: () => log?.add('enterSelection'),
    onExitSelectionMode: () => log?.add('exitSelection'),
    onMoveSelected: () => log?.add('move'),
  );

  MenuActionEntry action(List<MenuEntry> entries, String label) =>
      entries.whereType<MenuActionEntry>().firstWhere((e) => e.label == label);

  test('項目の並びと区切りは AppBar の並びを写したもの', () {
    final entries = build();

    expect(entries.whereType<MenuActionEntry>().map((e) => e.label), [
      '上の階層へ',
      '再読み込み',
      'フォルダを作成…',
      '複数選択',
      '選択を解除',
      '移動…',
    ]);
    expect(entries[2], isA<MenuGroupSeparator>());
    expect(entries[4], isA<MenuGroupSeparator>());
  });

  test('ダイアログを開く項目には … が付く（既存メニューの表記に揃える）', () {
    final labels = build()
        .whereType<MenuActionEntry>()
        .where((e) => e.label.endsWith('…'))
        .map((e) => e.label);

    expect(labels, ['フォルダを作成…', '移動…']);
  });

  test('再読み込みはどの状態でも常に有効', () {
    for (final selectionMode in [true, false]) {
      for (final canGoUp in [true, false]) {
        expect(
          action(
            build(selectionMode: selectionMode, canGoUp: canGoUp),
            '再読み込み',
          ).onSelected,
          isNotNull,
        );
      }
    }
  });

  group('上の階層へ', () {
    test('フォルダを開いていれば有効', () {
      expect(action(build(canGoUp: true), '上の階層へ').onSelected, isNotNull);
    });

    /// ルートでの AppBar leading は同じコールバックを出しているが、そちらは
    /// 「× で画面を閉じる」操作。メニューは行き先を名乗るので押せてはいけない。
    test('ルートに居るときは無効（× で閉じる操作とは別物）', () {
      expect(action(build(canGoUp: false), '上の階層へ').onSelected, isNull);
    });

    /// v1.57 までは選択モード中も有効で、**選択を抱えたまま親フォルダへ移動でき、
    /// いま見えていないファイルを別フォルダ基準の移動先ピッカーで動かせた**
    /// (#984)。選択モード中の戻る操作は `PopScope` が `_exitSelectionMode()` へ
    /// 振り分けていて上の階層へは行かないので、メニューだけが分岐を通っていな
    /// かった。
    test('⚠ 選択モード中は無効（AppBar 側の戻る操作と条件を揃える / #984）', () {
      expect(
        action(build(canGoUp: true, selectionMode: true), '上の階層へ').onSelected,
        isNull,
      );
    });

    /// 選択を解除してから移動する案は採らなかった。「上の階層へ」を選んだだけで
    /// 選択が消えるのは、メニューの他項目が選択を保つのと非対称になるため
    /// （#835「使えない操作は無効化して残す」）。ここが崩れるとその判断が
    /// ひっくり返ったことになる。
    test('⚠ 選択モードを抜ければまた有効になる（解除して移動する形にしない / #984）', () {
      expect(
        action(build(canGoUp: true, selectionMode: false), '上の階層へ').onSelected,
        isNotNull,
      );
    });
  });

  group('選択モードでない間', () {
    final entries = build(selectionMode: false);

    test('フォルダを作成・複数選択が有効', () {
      expect(action(entries, 'フォルダを作成…').onSelected, isNotNull);
      expect(action(entries, '複数選択').onSelected, isNotNull);
    });

    test('選択を解除・移動は無効', () {
      expect(action(entries, '選択を解除').onSelected, isNull);
      expect(action(entries, '移動…').onSelected, isNull);
    });
  });

  group('選択モード中', () {
    test('フォルダを作成・複数選択は無効（AppBar から消えるのと同じ条件）', () {
      final entries = build(selectionMode: true);

      expect(action(entries, 'フォルダを作成…').onSelected, isNull);
      expect(action(entries, '複数選択').onSelected, isNull);
    });

    test('選択を解除は選択件数によらず有効', () {
      for (final hasSelection in [true, false]) {
        expect(
          action(
            build(selectionMode: true, hasSelection: hasSelection),
            '選択を解除',
          ).onSelected,
          isNotNull,
        );
      }
    });

    test('移動は 1 件以上選択しているときだけ有効', () {
      expect(
        action(
          build(selectionMode: true, hasSelection: true),
          '移動…',
        ).onSelected,
        isNotNull,
      );
      expect(
        action(
          build(selectionMode: true, hasSelection: false),
          '移動…',
        ).onSelected,
        isNull,
      );
    });
  });

  test('各項目は対応するコールバックを呼ぶ', () {
    final log = <String>[];
    final available = build(canGoUp: true, log: log);
    for (final label in ['上の階層へ', '再読み込み', 'フォルダを作成…', '複数選択']) {
      action(available, label).onSelected!();
    }
    final selecting = build(selectionMode: true, hasSelection: true, log: log);
    for (final label in ['選択を解除', '移動…']) {
      action(selecting, label).onSelected!();
    }

    expect(log, [
      'up',
      'refresh',
      'createFolder',
      'enterSelection',
      'exitSelection',
      'move',
    ]);
  });

  /// #835 の約束: `onSelected` は名前付きメソッドのテアオフで渡すこと。同じ
  /// コールバックで組み直したら**値等価**になり、選択のトグルや自動 loadMore で
  /// 画面が再ビルドされてもメニューバー全体は作り直されない
  /// （[ScreenMenu.didUpdateWidget] がここで弾く）。
  test('同じコールバックで組み直せば値等価になる', () {
    void noop() {}

    List<MenuEntry> make() => buildDriveMenuEntries(
      canGoUp: true,
      selectionMode: false,
      hasSelection: false,
      onGoUp: noop,
      onRefresh: noop,
      onCreateFolder: noop,
      onEnterSelectionMode: noop,
      onExitSelectionMode: noop,
      onMoveSelected: noop,
    );

    expect(sameMenuEntries(make(), make()), isTrue);
  });

  /// この画面のコールバックには `Future<void>` を返すものが 2 つある
  /// （`_createFolder` / `_promptMoveSelectedFiles`）。既存 3 画面はすべて同期
  /// メソッドだったので、**戻り値の型が変わってもテアオフの値等価が保たれるか**は
  /// ここが初出になる。実測すると保たれる（`Future<void> Function()` から
  /// `VoidCallback` への代入は Dart の関数部分型で通り、ラッパは作られない）。
  ///
  /// 将来 `onCreateFolder: () => _createFolder()` のような無名関数に書き換えると
  /// **ビルドのたびに別物**になり、選択トグルや自動 loadMore の再ビルドごとに
  /// メニューバー全体が作り直される。それをここで落とす。
  test('async なインスタンスメソッドのテアオフでも値等価が保たれる', () {
    final screen = _FakeScreenState();

    List<MenuEntry> make() => buildDriveMenuEntries(
      canGoUp: true,
      selectionMode: true,
      hasSelection: true,
      onGoUp: screen.goUp,
      onRefresh: screen.refresh,
      onCreateFolder: screen.createFolder,
      onEnterSelectionMode: screen.enterSelectionMode,
      onExitSelectionMode: screen.exitSelectionMode,
      onMoveSelected: screen.moveSelected,
    );

    expect(sameMenuEntries(make(), make()), isTrue);
  });

  test('状態が変われば値等価は崩れる（メニューが出し直される）', () {
    void noop() {}

    List<MenuEntry> make({
      required bool canGoUp,
      required bool selectionMode,
      required bool hasSelection,
    }) => buildDriveMenuEntries(
      canGoUp: canGoUp,
      selectionMode: selectionMode,
      hasSelection: hasSelection,
      onGoUp: noop,
      onRefresh: noop,
      onCreateFolder: noop,
      onEnterSelectionMode: noop,
      onExitSelectionMode: noop,
      onMoveSelected: noop,
    );

    final base = make(
      canGoUp: false,
      selectionMode: false,
      hasSelection: false,
    );

    expect(
      sameMenuEntries(
        base,
        make(canGoUp: true, selectionMode: false, hasSelection: false),
      ),
      isFalse,
    );
    expect(
      sameMenuEntries(
        base,
        make(canGoUp: false, selectionMode: true, hasSelection: false),
      ),
      isFalse,
    );
    // 選択件数 0 → 1 は「移動…」の可否だけを動かす。
    expect(
      sameMenuEntries(
        make(canGoUp: false, selectionMode: true, hasSelection: false),
        make(canGoUp: false, selectionMode: true, hasSelection: true),
      ),
      isFalse,
    );
  });
}

/// 画面 State のコールバック構成だけを写したスタンド・イン。`_createFolder` /
/// `_promptMoveSelectedFiles` が `Future<void>` を返すのに合わせてある。
class _FakeScreenState {
  void goUp() {}
  void refresh() {}
  Future<void> createFolder() async {}
  void enterSelectionMode() {}
  void exitSelectionMode() {}
  Future<void> moveSelected() async {}
}
