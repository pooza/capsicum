import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'desktop_menu_model.dart';

/// iPad のメニューバー（iPadOS 26〜）へ、デスクトップと同じモデルを載せる
/// (#1268)。
///
/// ⚠⚠ **Flutter の `PlatformMenuBar` は iOS では動かない。**`flutter/menu`
/// チャンネルを受けているのは macOS のエンジンだけなので、ネイティブ
/// （`ios/Runner/AppDelegate.swift` の `MenuBarPlugin`）が `UIMenuBuilder` で組む。ここは
/// モデルを JSON にして渡し、選ばれた項目を id で受けて呼ぶだけ。
///
/// iPad にはシステムのメニュー（App / File / Edit / View / Window）が最初から
/// あるので、どこへ置くかをここで決める（[iosMenuPlacement]）。⚠ iPhone には
/// メニューバーが無い（ネイティブが `buildMenu` を呼ばれないので、送っても
/// 何も起きない）。
class IosMenuBridge {
  IosMenuBridge._();

  static const _channel = MethodChannel('capsicum/menu_bar');

  static String? _publishedShape;
  static int _generation = 0;
  static Map<int, VoidCallback> _callbacks = const {};
  static bool _listening = false;

  /// メニューバーを持っている shell の数（[IosMenuLifetime]）。
  static int _owners = 0;

  /// shell がメニューバーを持ち始めた。
  static void attach() => _owners++;

  /// shell が消えた。最後の 1 つなら、ネイティブのメニューとコールバックの
  /// 表を空にする。
  ///
  /// ⚠⚠ **ネイティブのメニューはウィジェットと一緒に消えない**（PR #1333 の
  /// Codex P2）。最後のアカウントを削除するとログイン画面（shell の外）へ
  /// 移るが、空にしないと「設定」「新規投稿」などが残り、選ぶと捨てられた
  /// shell の context を使って失敗する。
  static void detach() {
    if (_owners > 0) _owners--;
    if (_owners > 0) return;
    _callbacks = const {};
    _publishedShape = null;
    _generation++;
    _channel
        .invokeMethod<void>('setMenus', {
          'generation': _generation,
          'menus': const <Object>[],
        })
        .catchError((Object _) {});
  }

  /// [model] を送る。
  ///
  /// ⚠⚠ **比べるのは構造（文言・キー・有効か）だけ。**メニューの項目は build の
  /// たびに作り直されたラムダを持つので、項目の `==` で比べると毎回違って見え、
  /// 打鍵のたびにメニューを組み直すことになる。構造が同じなら id は同じ項目を
  /// 指すので、コールバックの表だけを差し替えて送らない。
  ///
  /// ⚠ 構造が変わったら世代を進めて送る。ネイティブが組み直す前に古いメニュー
  /// から届いた選択は、世代が違うので捨てる（id は位置の連番なので、項目が
  /// 増減すると別の操作を指す・#1332 のレビュー）。
  static void publish(List<MenuSubmenuEntry> model) {
    // shell が消えた後に、フレームの後の予約が届くことがある。
    if (_owners == 0) return;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_handle);
    }
    final callbacks = <int, VoidCallback>{};
    final menus = iosMenuPayload(model, callbacks);
    _callbacks = callbacks;
    final shape = jsonEncode(menus);
    if (shape == _publishedShape) return;
    _publishedShape = shape;
    _generation++;
    _channel
        .invokeMethod<void>('setMenus', {
          'generation': _generation,
          'menus': menus,
        })
        .catchError((Object _) {
          // メニューバーが無い（古い OS・テスト）ときは黙って捨てる。
        });
  }

  static Future<void> _handle(MethodCall call) async {
    if (call.method != 'menuSelected') return;
    final args = call.arguments;
    if (args is! Map) return;
    if (args['generation'] != _generation) return;
    final id = args['id'];
    if (id is int) _callbacks[id]?.call();
  }
}

/// メニューをどこへ置くか。ネイティブの `UIMenu.Identifier` に対応する。
enum IosMenuPlacement {
  /// アプリのメニュー（アプリ名の見出し）の先頭。
  application,

  /// File メニューの先頭。
  file,

  /// View メニューの先頭。
  view,

  /// Edit メニューの後ろに、新しいメニューとして入れる。
  afterEdit,

  /// 載せない（システムのメニューに任せる）。
  skip,
}

/// 最上位のメニューの置き場所 (#1268)。
///
/// - 「編集」はシステムの Edit に任せる。コピー・ペーストは UIKit が文字入力へ
///   届けるので、二重に並べると同じキーが 2 つになる
/// - 「ウインドウ」は中身が OS 提供の項目（最小化・ズーム）だけで、iPad では
///   システムの Window がその役
@visibleForTesting
IosMenuPlacement iosMenuPlacement(String label) => switch (label) {
  'capsicum' => IosMenuPlacement.application,
  'ファイル' => IosMenuPlacement.file,
  '表示' => IosMenuPlacement.view,
  '編集' || 'ウインドウ' => IosMenuPlacement.skip,
  _ => IosMenuPlacement.afterEdit,
};

/// [model] をネイティブへ渡す形にする。選択のコールバックは [callbacks] へ
/// id で積む。
///
/// ⚠ OS 提供の項目（[MenuProvidedEntry]）は落とす。iPad ではシステムの
/// メニューが同じ役（終了・隠す・全画面）を持っている。
@visibleForTesting
List<Map<String, Object?>> iosMenuPayload(
  List<MenuSubmenuEntry> model,
  Map<int, VoidCallback> callbacks,
) {
  // ⚠ 無効な項目（表に積まない）にも番号を振る。表の大きさで数えると、無効な
  // 項目と次の項目が同じ id になる。
  var nextId = 0;
  Map<String, Object?>? item(MenuEntry e) {
    switch (e) {
      case MenuActionEntry():
        final onSelected = e.onSelected;
        final id = ++nextId;
        if (onSelected != null) callbacks[id] = onSelected;
        final shortcut = e.shortcut;
        return {
          'type': 'action',
          'id': id,
          'title': e.badge > 0 ? '${e.label}（${e.badge}）' : e.label,
          'enabled': onSelected != null,
          'checked': e.checked == true,
          if (shortcut != null) 'input': iosKeyInput(shortcut.key),
          if (shortcut != null) 'shift': shortcut.shift,
        };
      case MenuSubmenuEntry():
        return {
          'type': 'submenu',
          'title': e.label,
          'children': [for (final c in e.children) ?item(c)],
        };
      case MenuGroupSeparator():
        return const {'type': 'separator'};
      case MenuProvidedEntry():
        return null;
    }
  }

  return [
    for (final menu in model)
      if (iosMenuPlacement(menu.label) != IosMenuPlacement.skip)
        {
          'placement': iosMenuPlacement(menu.label).name,
          'title': menu.label,
          'children': [for (final c in menu.children) ?item(c)],
        },
  ];
}

/// `UIKeyCommand` の `input`（Cmd と組む文字）。⚠ 英字は小文字で渡す
/// （Shift は修飾キーとして別に付ける）。
@visibleForTesting
String? iosKeyInput(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (label.length != 1) return null;
  return label.toLowerCase();
}

/// iPad のメニューバーを、認証後の shell（[child] を包む `DesktopMenuBar`）の
/// 寿命に結びつける (#1268・PR #1333 の Codex P2)。
class IosMenuLifetime extends StatefulWidget {
  const IosMenuLifetime({super.key, required this.child});

  final Widget child;

  @override
  State<IosMenuLifetime> createState() => _IosMenuLifetimeState();
}

class _IosMenuLifetimeState extends State<IosMenuLifetime> {
  @override
  void initState() {
    super.initState();
    IosMenuBridge.attach();
  }

  @override
  void dispose() {
    IosMenuBridge.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
