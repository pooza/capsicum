import 'package:capsicum/src/ui/screen/post_detail_screen.dart';
import 'package:capsicum/src/ui/widget/desktop_menu_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// #912: スレッド画面のデスクトップメニュー項目。
///
/// 眼目は #835 で決めた「**出し分けの条件は画面のツールバー / メニュー側と
/// 同一にする。使えない操作をメニューにだけ見せない**」。スレッドが 1 件の
/// ときはジャンプ用の FAB が出ないので、メニュー側も押せてはいけない。
void main() {
  List<MenuEntry> build({required bool showJump, List<String>? log}) =>
      buildThreadMenuEntries(
        showJump: showJump,
        onJumpToTop: () => log?.add('top'),
        onJumpToBottom: () => log?.add('bottom'),
        onReload: () => log?.add('reload'),
      );

  MenuActionEntry action(List<MenuEntry> entries, String label) =>
      entries.whereType<MenuActionEntry>().firstWhere((e) => e.label == label);

  test('項目の並びは 先頭へ / 末尾へ / 区切り / 再読み込み', () {
    final entries = build(showJump: true);

    expect(entries.length, 4);
    expect(entries[2], isA<MenuGroupSeparator>());
    expect(entries.whereType<MenuActionEntry>().map((e) => e.label), [
      '先頭へ',
      '末尾へ',
      '再読み込み',
    ]);
  });

  test('スレッドが複数件ならジャンプが有効', () {
    final entries = build(showJump: true);

    expect(action(entries, '先頭へ').onSelected, isNotNull);
    expect(action(entries, '末尾へ').onSelected, isNotNull);
  });

  test('スレッドが 1 件のときはジャンプが無効（FAB が出ない条件と揃える）', () {
    final entries = build(showJump: false);

    expect(action(entries, '先頭へ').onSelected, isNull);
    expect(action(entries, '末尾へ').onSelected, isNull);
  });

  test('再読み込みはスレッドの件数によらず常に有効', () {
    for (final showJump in [true, false]) {
      expect(action(build(showJump: showJump), '再読み込み').onSelected, isNotNull);
    }
  });

  test('各項目は対応するコールバックを呼ぶ', () {
    final log = <String>[];
    final entries = build(showJump: true, log: log);

    action(entries, '先頭へ').onSelected!();
    action(entries, '末尾へ').onSelected!();
    action(entries, '再読み込み').onSelected!();

    expect(log, ['top', 'bottom', 'reload']);
  });

  /// #835 の約束: `onSelected` は名前付きメソッドのテアオフで渡すこと。同じ
  /// コールバックで組み直したら**値等価**になり、画面の再ビルドでメニューバー
  /// 全体が作り直されない（[ScreenMenu.didUpdateWidget] がここで弾く）。
  test('同じコールバックで組み直せば値等価になる', () {
    void top() {}
    void bottom() {}
    void reload() {}

    List<MenuEntry> make() => buildThreadMenuEntries(
      showJump: true,
      onJumpToTop: top,
      onJumpToBottom: bottom,
      onReload: reload,
    );

    expect(sameMenuEntries(make(), make()), isTrue);
  });

  test('ジャンプの可否が変われば値等価は崩れる（メニューが出し直される）', () {
    void noop() {}

    List<MenuEntry> make({required bool showJump}) => buildThreadMenuEntries(
      showJump: showJump,
      onJumpToTop: noop,
      onJumpToBottom: noop,
      onReload: noop,
    );

    expect(
      sameMenuEntries(make(showJump: true), make(showJump: false)),
      isFalse,
    );
  });
}
