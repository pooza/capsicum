import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../constants.dart';

/// デスクトップ常駐モード (#752)。オンのとき、メインウィンドウを閉じても
/// アプリを終了させず、システムトレイ (Windows / Linux) / メニューバー
/// (macOS) に常駐させる。常駐中も #569 の WebSocket streaming が生き続ける
/// ため、ウィンドウを閉じた状態でも通知を受け取れる。
///
/// WNS ネイティブ push (#474) は割に合わず先送りにしたため、Windows の
/// 「ウィンドウを閉じても通知を受ける」体験はこの常駐 + WebSocket が担う。
///
/// 設定 (`residentModeProvider`) の値変化を [setEnabled] で受け、close 傍受
/// (window_manager の preventClose) とトレイ常駐を動的に張り替える。preventClose
/// は常駐 ON のときだけ立てるので、OFF 時はウィンドウを閉じれば通常どおり
/// 終了する（本サービスのバグでアプリが閉じられなくなる事故を避ける）。
class ResidentModeService with WindowListener, TrayListener {
  ResidentModeService._();
  static final ResidentModeService instance = ResidentModeService._();

  /// 常駐モードを UI に露出する OS。実装コード自体は全デスクトップで動くが、
  /// v1.40 では検証面の都合で Windows のみ有効化する。macOS（メニューバー）/
  /// Linux（トレイ）の検証と有効化は #757 (v1.42) で行い、ここを広げる。
  static bool get isSupported => Platform.isWindows;

  bool _enabled = false;
  bool _trayCreated = false;
  bool _attached = false;

  /// Windows は .ico が確実。macOS / Linux は flutter asset の png を使う
  /// （macOS は base64 化、Linux は libappindicator が png を扱える）。
  String get _iconAsset => Platform.isWindows
      ? 'assets/images/tray_icon.ico'
      : 'assets/images/logo.png';

  /// window / tray のリスナー登録。サポート OS の起動時に 1 度だけ呼ぶ。
  void attach() {
    if (!isSupported || _attached) return;
    windowManager.addListener(this);
    trayManager.addListener(this);
    _attached = true;
  }

  /// 常駐モードの有効/無効を適用する。`residentModeProvider` の初期値適用と
  /// 値変化の双方から呼ぶ。冪等。未サポート OS では何もしない。
  Future<void> setEnabled(bool value) async {
    if (!isSupported) return;
    _enabled = value;
    try {
      if (value) {
        await windowManager.setPreventClose(true);
        await _ensureTray();
      } else {
        await windowManager.setPreventClose(false);
        await _removeTray();
        // 常駐 OFF をウィンドウ非表示中に行うと操作不能になるため復帰させる。
        if (!await windowManager.isVisible()) {
          await _showWindow();
        }
      }
    } catch (e) {
      debugPrint('capsicum: resident_mode: setEnabled($value) failed: $e');
    }
  }

  Future<void> _ensureTray() async {
    if (_trayCreated) return;
    await trayManager.setIcon(_iconAsset);
    await trayManager.setToolTip(AppConstants.appName);
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: _kShow, label: '${AppConstants.appName} を表示'),
          MenuItem.separator(),
          MenuItem(key: _kExit, label: '終了'),
        ],
      ),
    );
    _trayCreated = true;
  }

  Future<void> _removeTray() async {
    if (!_trayCreated) return;
    await trayManager.destroy();
    _trayCreated = false;
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // --- WindowListener ---

  @override
  void onWindowClose() async {
    // preventClose(true) のとき（= 常駐 ON）だけ呼ばれる。プロセスを残して
    // トレイに退避する。トレイが何らかの理由で未作成でも再生成を試みる。
    if (!_enabled) return;
    await _ensureTray();
    await windowManager.hide();
  }

  // --- TrayListener ---

  @override
  void onTrayIconMouseDown() {
    // Windows / Linux: 左クリックでウィンドウ復帰。
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _kShow:
        _showWindow();
      case _kExit:
        // 明示終了。preventClose を解いてから destroy し、onWindowClose の
        // hide 分岐に吸われず確実にプロセスを終わらせる。
        _enabled = false;
        windowManager.setPreventClose(false);
        windowManager.destroy();
    }
  }

  static const _kShow = 'show';
  static const _kExit = 'exit';
}
