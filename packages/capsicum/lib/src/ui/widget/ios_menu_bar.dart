import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  static List<MenuSubmenuEntry>? _published;
  static Map<int, VoidCallback> _callbacks = const {};
  static bool _listening = false;

  /// [model] を送る。前回と同じ中身なら送らない（画面は打鍵のたびに作り直さ
  /// れるので、比べずに送るとメニューを毎回組み直すことになる）。
  static void publish(List<MenuSubmenuEntry> model) {
    final published = _published;
    if (published != null && sameMenuEntries(published, model)) return;
    _published = model;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_handle);
    }
    final callbacks = <int, VoidCallback>{};
    final payload = iosMenuPayload(model, callbacks);
    _callbacks = callbacks;
    _channel.invokeMethod<void>('setMenus', payload).catchError((Object _) {
      // メニューバーが無い（古い OS・テスト）ときは黙って捨てる。
    });
  }

  static Future<void> _handle(MethodCall call) async {
    if (call.method != 'menuSelected') return;
    final id = call.arguments;
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
  Map<String, Object?>? item(MenuEntry e) {
    switch (e) {
      case MenuActionEntry():
        final onSelected = e.onSelected;
        final id = callbacks.length + 1;
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
