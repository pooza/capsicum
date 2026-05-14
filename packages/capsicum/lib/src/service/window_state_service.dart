import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// デスクトップ (macOS / Linux / Windows) のウィンドウ位置・サイズ・最大化
/// 状態を起動間で記録 / 復元するサービス (#559)。
///
/// 実況用途で「アプリをいつも同じ場所に置く」運用 (e.g. Amazon Prime Video と
/// 左右並列) を支えるため、ユーザー設定 (on/off) は持たず常時動作する。
///
/// モバイル (iOS / Android) ではウィンドウ概念が無く window_manager の native
/// plugin も登録されないため、[init] は早期 return する。
class WindowStateService with WindowListener {
  static const _kX = 'window_state.x';
  static const _kY = 'window_state.y';
  static const _kWidth = 'window_state.width';
  static const _kHeight = 'window_state.height';
  static const _kMaximized = 'window_state.maximized';

  static const _defaultSize = Size(1024, 768);
  static const _minSize = Size(640, 480);
  static const _saveDebounce = Duration(milliseconds: 500);

  Timer? _saveTimer;
  bool _initialized = false;

  static bool get _isDesktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  Future<void> init() async {
    if (!_isDesktop) return;
    await windowManager.ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final savedX = prefs.getDouble(_kX);
    final savedY = prefs.getDouble(_kY);
    final savedWidth = prefs.getDouble(_kWidth);
    final savedHeight = prefs.getDouble(_kHeight);
    final savedMaximized = prefs.getBool(_kMaximized) ?? false;

    // setSize / setPosition は waitUntilReadyToShow 内で呼ぶことで Flutter
    // runner がウィンドウを show する直前に適用される (短いがちらつきは残る。
    // 完全に潰すには native runner を hidden start に切り替える必要があり、
    // 今回はスコープ外)。
    final restoreSize = (savedWidth != null && savedHeight != null)
        ? Size(savedWidth, savedHeight)
        : _defaultSize;
    final hasPosition = savedX != null && savedY != null;

    final options = WindowOptions(
      size: restoreSize,
      minimumSize: _minSize,
      center: !hasPosition,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (hasPosition) {
        await windowManager.setPosition(Offset(savedX, savedY));
      }
      if (savedMaximized) {
        await windowManager.maximize();
      }
      await windowManager.show();
      await windowManager.focus();
    });

    windowManager.addListener(this);
    _initialized = true;
  }

  void dispose() {
    if (!_initialized) return;
    windowManager.removeListener(this);
    _saveTimer?.cancel();
    _saveTimer = null;
    _initialized = false;
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _save);
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final maximized = await windowManager.isMaximized();
      await prefs.setBool(_kMaximized, maximized);
      // 最大化中は bounds が画面いっぱいになり復元用としては不適切なので、
      // 最大化中は前回値を保持する (= ここで position / size の書き換えを
      // スキップ)。これで「最大化前のサイズに戻して再起動」の挙動が成り立つ。
      if (!maximized) {
        final bounds = await windowManager.getBounds();
        await prefs.setDouble(_kX, bounds.left);
        await prefs.setDouble(_kY, bounds.top);
        await prefs.setDouble(_kWidth, bounds.width);
        await prefs.setDouble(_kHeight, bounds.height);
      }
    } catch (e, st) {
      // ウィンドウ状態の永続化失敗はユーザー体験に致命的でないため warning
      // 止まり。Sentry には流さず debugPrint のみ。
      if (kDebugMode) {
        // ignore: avoid_print
        print('WindowStateService save failed: $e\n$st');
      }
    }
  }

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  @override
  void onWindowClose() {
    // close 時はデバウンスを待たず即時保存。OS はそのままウィンドウを破棄
    // するため、await できる時間は限定的だが、setPreventClose を使わない
    // 軽量実装で許容する (close 直前の数十 ms の状態は失う可能性あり)。
    _saveTimer?.cancel();
    _save();
  }
}
