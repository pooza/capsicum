/// デスクトップメニューの単一モデル (#841)。
///
/// #713 で macOS（native NSMenu = `PlatformMenu*`）と Windows/Linux（in-window の
/// Material `MenuBar`）にメニューバーを導入したが、メニューの骨格が 2 つのビルダーに
/// 別々の型で書き下されてドリフトの発生源になっていた。ここでは「どのメニューに何が
/// どの順で並ぶか」を **1 回だけ** この抽象モデルで定義し、薄い 2 レンダラ
/// （[renderMacMenuBar] / [renderInWindowMenuBar]）が各 UI に変換する。プラット
/// フォーム差（アイコン有無・OS 提供項目・主修飾キー・チェック表現）はレンダラと
/// [MenuShortcut] の 1 箇所に閉じ込める。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// メニュー項目のショートカット。**主修飾キー**（macOS は Cmd=meta、Windows/Linux
/// は Ctrl）をモデルから抽象化し、解決は [resolve] に一元化する (#841)。従来 mac は
/// meta・in-window は control を各ビルダーに直書きしていた差異をここへ集約する。
class MenuShortcut {
  const MenuShortcut(this.key, {this.shift = false});

  final LogicalKeyboardKey key;
  final bool shift;

  /// [useMeta] が true なら Cmd（macOS）、false なら Ctrl（Windows/Linux）で解決する。
  SingleActivator resolve({required bool useMeta}) =>
      SingleActivator(key, meta: useMeta, control: !useMeta, shift: shift);

  @override
  bool operator ==(Object other) =>
      other is MenuShortcut && other.key == key && other.shift == shift;

  @override
  int get hashCode => Object.hash(key, shift);
}

/// メニューツリーの 1 ノード。
///
/// 各ノードは**値等価**を持つ (#835)。画面メニューの貢献（[ScreenMenu]）は画面が
/// 再ビルドされるたびに新しいリストとして組み直されるため、同一性で比較すると
/// 本文を 1 文字打つたびにメニューバー全体が再構築されてしまう。中身が同じなら
/// 等しいと判定できるようにして、状態が実際に変わったときだけ作り直す。
///
/// 等価判定は `onSelected` も含む。**コールバックはメソッドのテアオフで渡すこと**
/// （`onSelected: _pickMedia`）。同じレシーバの同じメソッドのテアオフ同士は Dart の
/// 仕様で等しくなるが、その場で作った無名関数（`() => setState(...)`）はビルドの
/// たびに別物になり、等価判定が常に false に落ちる。
sealed class MenuEntry {
  const MenuEntry();
}

/// 通常のアクション項目。
class MenuActionEntry extends MenuEntry {
  const MenuActionEntry({
    required this.label,
    this.icon,
    this.shortcut,
    this.onSelected,
    this.badge = 0,
    this.checked,
    this.globalShortcut = false,
  });

  final String label;

  /// in-window レンダラのみ使用する先頭アイコン。macOS はネイティブメニューに
  /// アイコンを付けない慣例（HIG）のため落とす。
  final IconData? icon;

  /// 表示＋発火用のショートカット。主修飾キーは [MenuShortcut] が吸収する。
  final MenuShortcut? shortcut;

  final VoidCallback? onSelected;

  /// >0 のときラベルに `（N）` を付ける（お知らせ未読等）。
  final int badge;

  /// チェック項目の状態。null なら非チェック項目。macOS は
  /// [PlatformMenuItem] にチェック API が無いためラベル末尾に `✓` を埋め込み、
  /// in-window は先頭アイコンで表す (#841/#835)。
  final bool? checked;

  /// true のとき、in-window（Windows/Linux）でこの [shortcut] をアプリ級の
  /// [CallbackShortcuts] に登録し、メニューを開かずキー操作だけで発火させる
  /// (#841)。macOS は native メニューが [shortcut] を自前で発火するため無関係。
  /// 編集（コピー/貼り付け等）は [DefaultTextEditingShortcuts] が担うので false の
  /// まま（表示専用）にし、二重登録・二重発火を避ける。
  final bool globalShortcut;

  @override
  bool operator ==(Object other) =>
      other is MenuActionEntry &&
      other.label == label &&
      other.icon == icon &&
      other.shortcut == shortcut &&
      other.onSelected == onSelected &&
      other.badge == badge &&
      other.checked == checked &&
      other.globalShortcut == globalShortcut;

  @override
  int get hashCode => Object.hash(
    label,
    icon,
    shortcut,
    onSelected,
    badge,
    checked,
    globalShortcut,
  );
}

/// in-window（Windows/Linux）でアプリ級に登録するショートカット束を [model] から
/// 集める (#841)。`globalShortcut: true` の項目のみを Ctrl 修飾で解決する。macOS は
/// native メニューが発火するため呼ばない。
Map<ShortcutActivator, VoidCallback> collectInWindowShortcuts(
  List<MenuEntry> model,
) {
  final bindings = <ShortcutActivator, VoidCallback>{};
  void walk(MenuEntry e) {
    switch (e) {
      case MenuActionEntry():
        final shortcut = e.shortcut;
        final onSelected = e.onSelected;
        if (e.globalShortcut && shortcut != null && onSelected != null) {
          bindings[shortcut.resolve(useMeta: false)] = onSelected;
        }
      case MenuSubmenuEntry():
        e.children.forEach(walk);
      case MenuProvidedEntry():
      case MenuGroupSeparator():
        break;
    }
  }

  model.forEach(walk);
  return bindings;
}

/// サブメニュー（メニューの見出し）。
class MenuSubmenuEntry extends MenuEntry {
  const MenuSubmenuEntry({
    required this.label,
    this.leadingIcon,
    required this.children,
  });

  final String label;

  /// in-window の見出しに付ける先頭アイコン（capsicum のブランドアイコン等）。
  final Widget? leadingIcon;

  final List<MenuEntry> children;

  @override
  bool operator ==(Object other) =>
      other is MenuSubmenuEntry &&
      other.label == label &&
      other.leadingIcon == leadingIcon &&
      sameMenuEntries(other.children, children);

  @override
  int get hashCode => Object.hash(label, leadingIcon, Object.hashAll(children));
}

/// メニュー項目リストの値等価 (#835)。要素の `==`（[MenuEntry] の値等価）で比べる。
bool sameMenuEntries(List<MenuEntry> a, List<MenuEntry> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// グループ境界（区切り線）。macOS は [PlatformMenuItemGroup] の分割に、in-window
/// は現状セパレータを描かないため無視する（従来挙動維持）。
class MenuGroupSeparator extends MenuEntry {
  const MenuGroupSeparator();

  @override
  bool operator ==(Object other) => other is MenuGroupSeparator;

  @override
  int get hashCode => (MenuGroupSeparator).hashCode;
}

/// OS 提供項目。macOS は [PlatformProvidedMenuItem]（About/終了/Services/全画面/
/// 最小化/ズーム等）へ、in-window は [inWindowAction] があれば `windowManager`
/// 等で代替する。[inWindowAction] が null の項目（Services/Hide/Quit 等）は
/// macOS 専用で、in-window レンダラはスキップする。
class MenuProvidedEntry extends MenuEntry {
  const MenuProvidedEntry({
    required this.macType,
    this.inWindowLabel,
    this.inWindowIcon,
    this.inWindowAction,
  });

  final PlatformProvidedMenuItemType macType;
  final String? inWindowLabel;
  final IconData? inWindowIcon;
  final Future<void> Function()? inWindowAction;

  @override
  bool operator ==(Object other) =>
      other is MenuProvidedEntry &&
      other.macType == macType &&
      other.inWindowLabel == inWindowLabel &&
      other.inWindowIcon == inWindowIcon &&
      other.inWindowAction == inWindowAction;

  @override
  int get hashCode =>
      Object.hash(macType, inWindowLabel, inWindowIcon, inWindowAction);
}

/// ラベルに badge / checked を反映した最終表示文字列を組む。checked の `✓` は
/// macOS 専用（in-window はアイコンで表すため付けない）。
String _decoratedLabel(MenuActionEntry e, {required bool withCheckMark}) {
  var label = e.badge > 0 ? '${e.label}（${e.badge}）' : e.label;
  if (withCheckMark && e.checked == true) label = '$label ✓';
  return label;
}

/// モデルを macOS の native メニュー（[PlatformMenuBar]）へ変換する (#841)。
/// アイコンは落とし（HIG）、ショートカットは Cmd で解決、OS 提供項目は
/// [PlatformProvidedMenuItem] に写す。チェックはラベル末尾の `✓` で表す。
Widget renderMacMenuBar(List<MenuSubmenuEntry> model, Widget child) {
  return PlatformMenuBar(
    menus: [for (final menu in model) _macSubmenu(menu)],
    child: child,
  );
}

PlatformMenu _macSubmenu(MenuSubmenuEntry menu) {
  // MenuGroupSeparator で子を区切り、各区間を PlatformMenuItemGroup にまとめる
  // ことで、macOS のグループ間セパレータ（従来の PlatformMenuItemGroup 分割）を
  // 再現する。区切りが無ければフラットに並べる。
  final groups = <List<MenuEntry>>[[]];
  for (final e in menu.children) {
    if (e is MenuGroupSeparator) {
      if (groups.last.isNotEmpty) groups.add([]);
    } else {
      groups.last.add(e);
    }
  }
  final nonEmpty = groups.where((g) => g.isNotEmpty).toList();
  final List<PlatformMenuItem> items;
  if (nonEmpty.length <= 1) {
    items = [for (final e in menu.children) ..._macItems(e)];
  } else {
    items = [
      for (final g in nonEmpty)
        PlatformMenuItemGroup(members: [for (final e in g) ..._macItems(e)]),
    ];
  }
  return PlatformMenu(label: menu.label, menus: items);
}

List<PlatformMenuItem> _macItems(MenuEntry e) {
  switch (e) {
    case MenuActionEntry():
      return [
        PlatformMenuItem(
          label: _decoratedLabel(e, withCheckMark: true),
          shortcut: e.shortcut?.resolve(useMeta: true),
          onSelected: e.onSelected,
        ),
      ];
    case MenuSubmenuEntry():
      return [_macSubmenu(e)];
    case MenuProvidedEntry():
      return [PlatformProvidedMenuItem(type: e.macType)];
    case MenuGroupSeparator():
      // グループ化は _macSubmenu が処理するため、ここに来た区切りは無視する。
      return const [];
  }
}

/// モデルを Windows/Linux の in-window メニューバー（Material [MenuBar]）へ変換
/// する (#841)。先頭アイコン（leadingIcon）を付け、ショートカットは Ctrl で表示、
/// OS 提供項目は `windowManager` 等の代替アクションに写す（mac 専用項目はスキップ）。
/// チェックは先頭アイコンの ✓/空で表す。
Widget renderInWindowMenuBar(List<MenuSubmenuEntry> model, Widget child) {
  // メニュー表示の詰め (#713): ドロップダウンに最小幅を与え、各項目に左右マージンと
  // 左アイコンを付けて左端を揃える。
  final submenuStyle = MenuStyle(
    minimumSize: const WidgetStatePropertyAll(Size(248, 0)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
  );
  final itemStyle = MenuItemButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
  );

  // Windows/Linux の Material メニューは shortcut を表示するだけで発火しない
  // ため、`globalShortcut` 項目をアプリ級 [CallbackShortcuts] に登録して、メニュー
  // を開かずキー操作で発火させる (#841)。編集系は DefaultTextEditingShortcuts が
  // 担うので登録しない（二重発火回避）。
  final bindings = collectInWindowShortcuts(model);
  final bar = Column(
    // メニューバーはウィンドウ幅いっぱいに伸ばし、項目は左寄せにする (#713)。
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MenuBar(
        children: [
          for (final menu in model)
            SubmenuButton(
              menuStyle: submenuStyle,
              leadingIcon: menu.leadingIcon,
              menuChildren: [
                for (final e in menu.children)
                  ..._inWindowItems(e, submenuStyle, itemStyle),
              ],
              child: Text(menu.label),
            ),
        ],
      ),
      Expanded(child: child),
    ],
  );
  if (bindings.isEmpty) return bar;
  // [CallbackShortcuts] は「配下にフォーカスがあるとき」だけキーを拾う (Flutter 本体
  // 仕様)。ホームでタイムラインを眺めているだけの状態は本文のどこにもフォーカスが
  // 無く、キーイベントがこのノードより上位のフォーカススコープへ流れて bindings が
  // 参照されない。autofocus な [Focus] で既定フォーカスを本サブツリー内に保持し、
  // 起動直後からショートカットを発火可能にする (#841)。
  return CallbackShortcuts(
    bindings: bindings,
    child: Focus(autofocus: true, child: bar),
  );
}

List<Widget> _inWindowItems(
  MenuEntry e,
  MenuStyle submenuStyle,
  ButtonStyle itemStyle,
) {
  Icon menuIcon(IconData data) => Icon(data, size: 18);
  switch (e) {
    case MenuActionEntry():
      // チェック項目は先頭アイコンを ✓/空で表す。非チェック項目は本来のアイコン。
      final Widget? leading = e.checked != null
          ? menuIcon(e.checked! ? Icons.check : Icons.check_box_outline_blank)
          : (e.icon != null ? menuIcon(e.icon!) : null);
      return [
        MenuItemButton(
          style: itemStyle,
          leadingIcon: leading,
          shortcut: e.shortcut?.resolve(useMeta: false),
          onPressed: e.onSelected,
          child: Text(_decoratedLabel(e, withCheckMark: false)),
        ),
      ];
    case MenuSubmenuEntry():
      return [
        SubmenuButton(
          menuStyle: submenuStyle,
          leadingIcon: e.leadingIcon,
          menuChildren: [
            for (final c in e.children)
              ..._inWindowItems(c, submenuStyle, itemStyle),
          ],
          child: Text(e.label),
        ),
      ];
    case MenuProvidedEntry():
      // mac 専用の OS 提供項目（Services/Hide/Quit 等）は in-window では出さない。
      if (e.inWindowAction == null) return const [];
      return [
        MenuItemButton(
          style: itemStyle,
          leadingIcon: e.inWindowIcon != null
              ? menuIcon(e.inWindowIcon!)
              : null,
          onPressed: () => e.inWindowAction!(),
          child: Text(e.inWindowLabel ?? ''),
        ),
      ];
    case MenuGroupSeparator():
      // in-window は従来どおりセパレータを描かない（挙動維持）。
      return const [];
  }
}
