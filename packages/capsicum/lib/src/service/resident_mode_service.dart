import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../constants.dart';
import '../util/exception_scrub.dart';

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
  /// 検証面の都合で OS ごとに段階的に有効化する。Windows は v1.40、macOS
  /// （メニューバー = NSStatusItem）は #757 で実機検証して追加。Linux（トレイ
  /// = StatusNotifierItem）も #757 で追加。Linux ではトレイを持たない DE
  /// （拡張なしの GNOME 等）でアイコンが不可視になりうるため、close 時に
  /// トレイのホスト有無を DBus で検出し（[_linuxTrayHostAvailable]）、ホストが
  /// 居れば hide（タスクバーからも消す）、居なければ最小化に倒す。これで
  /// どの DE でもウィンドウを見失わない（クラッシュではなく安全側に倒す）。
  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// macOS のみ。常駐状態をネイティブ (AppDelegate) に伝え、ウィンドウを閉じても
  /// プロセスを終了させないための channel。window_manager の preventClose が macOS
  /// embedder では close を止めきれないため、終了抑止はネイティブ側で行う（#757）。
  static const _residentChannel = MethodChannel('capsicum/resident');

  bool _enabled = false;
  bool _trayCreated = false;
  bool _attached = false;

  /// Windows は .ico が確実。macOS はメニューバー用にモノクロ template png
  /// （黒シルエット + alpha。`isTemplate` でライト/ダークのメニューバーに自動
  /// 追従する。フルカラーの logo.png を template 指定すると黒塗り矩形になる）。
  /// Linux（libayatana-appindicator）はフルカラー png をそのまま使うので、
  /// 横長の logo.png ではなく正方形のアプリアイコン（tray_icon_linux.png・
  /// app_icon 256px 由来）を使う。横長画像はトレイで潰れて見えるため。
  String get _iconAsset => Platform.isWindows
      ? 'assets/images/tray_icon.ico'
      : Platform.isMacOS
      ? 'assets/images/tray_icon_macos_template.png'
      : 'assets/images/tray_icon_linux.png';

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
    // macOS: ウィンドウを閉じてもプロセスを残すかをネイティブへ伝える。
    // window 操作より先に伝えておき、close と入れ違っても終了抑止が効くようにする。
    if (Platform.isMacOS) {
      try {
        await _residentChannel.invokeMethod<void>('setResidentActive', value);
      } catch (e, st) {
        // pref（真実源）とネイティブの終了抑止状態が黙って乖離すると、UI は
        // 常駐 ON のままウィンドウを閉じてもアプリが落ちる（ユーザーには無反応に
        // 見える）。兄弟サービス launch_at_login (#763) と同じく Sentry に記録して
        // 乖離を可視化する。debugPrint だけでは本番で観測できないため。
        debugLogException(
          'capsicum: resident_mode: native sync($value) failed',
          e,
        );
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('service', 'resident_mode');
            scope.setTag('desired', value.toString());
          },
        );
      }
    }
    try {
      if (value) {
        await windowManager.setPreventClose(true);
        await _ensureTray();
      } else {
        await windowManager.setPreventClose(false);
        await _removeTray();
        // 常駐 OFF をウィンドウ非表示 / 最小化中に行うと操作不能になるため
        // 復帰させる。Linux は close で最小化に退避する（hide しない）ため
        // isMinimized も確認する。
        if (!await windowManager.isVisible() ||
            await windowManager.isMinimized()) {
          await _showWindow();
        }
      }
    } catch (e) {
      debugLogException(
        'capsicum: resident_mode: setEnabled($value) failed',
        e,
      );
    }
  }

  Future<void> _ensureTray() async {
    if (_trayCreated) return;
    // macOS のメニューバーは template 画像（モノクロ）として描かせる。これで
    // システムがライト/ダークやハイライト時の色を自動で塗り分ける。Windows /
    // Linux は通常のカラーアイコンなので isTemplate は無視される。
    await trayManager.setIcon(_iconAsset, isTemplate: Platform.isMacOS);
    // setToolTip は tray_manager の Linux 実装に存在せず（AppIndicator /
    // StatusNotifierItem はツールチップの概念を持たない）、呼ぶと
    // MissingPluginException を投げて以降の setContextMenu（表示 / 終了
    // メニュー）まで巻き添えで失敗する。Linux では飛ばす (#757)。
    if (!Platform.isLinux) {
      await trayManager.setToolTip(AppConstants.appName);
    }
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
    // macOS: Dock / アプリスイッチャに戻す（.regular）。隠していた間は .accessory
    // で Dock から消えているため、show より前に戻さないと最前面化が効きにくい。
    await _setDockIconHidden(false);
    await windowManager.show();
    await windowManager.focus();
  }

  /// macOS のみ。Dock アイコンの出し入れをネイティブに依頼する。Windows は
  /// 概念が無いので何もしない。
  Future<void> _setDockIconHidden(bool hidden) async {
    if (!Platform.isMacOS) return;
    try {
      await _residentChannel.invokeMethod<void>('setDockIconHidden', hidden);
    } catch (e) {
      debugLogException(
        'capsicum: resident_mode: setDockIconHidden($hidden) failed',
        e,
      );
    }
  }

  /// Linux のみ。SNI トレイのホスト（パネル側の表示先）が登録されているかを
  /// DBus で問い合わせる。KDE / LXQt / トレイ拡張入り GNOME 等では true、
  /// 拡張なしの GNOME 等では false。これにより close 時に「タスクバーから
  /// 消す hide」か「タスクバーに残す最小化」かを選び分ける ([onWindowClose])。
  ///
  /// watcher 不在・取得失敗・タイムアウト時は **false（最小化フォールバック）**
  /// を返す。トレイが見える保証が無い状態で hide すると復帰手段を失うため、
  /// 不明なら安全側に倒す。
  Future<bool> _linuxTrayHostAvailable() async {
    if (!Platform.isLinux) return true;
    final client = DBusClient.session();
    try {
      final watcher = DBusRemoteObject(
        client,
        name: 'org.kde.StatusNotifierWatcher',
        path: DBusObjectPath('/StatusNotifierWatcher'),
      );
      final value = await watcher
          .getProperty(
            'org.kde.StatusNotifierWatcher',
            'IsStatusNotifierHostRegistered',
          )
          .timeout(const Duration(seconds: 1));
      return value.asBoolean();
    } catch (e) {
      debugLogException('capsicum: resident_mode: tray host probe failed', e);
      return false;
    } finally {
      await client.close();
    }
  }

  // --- WindowListener ---

  @override
  void onWindowClose() async {
    // 常駐 ON のときだけ退避する。macOS は window_manager の preventClose が
    // close を止めきれず close イベントだけ出る（実際には閉じる）ため、終了抑止
    // 自体はネイティブ (#757) に任せ、ここでは（閉じきる前に）ウィンドウを hide
    // してトレイ退避の体裁を整える。Windows / Linux は GTK / Win32 embedder で
    // preventClose（delete-event で TRUE を返す）が効くので閉じない。
    if (!_enabled) return;
    await _ensureTray();
    if (Platform.isLinux) {
      // Linux: トレイの表示先（SNI ホスト＝パネル側）が居れば hide して
      // タスクバーからも消す（トレイから復帰）。居ない環境（トレイ拡張なしの
      // GNOME 等）で hide すると復帰手段を失う（ウィンドウ迷子）ため、その
      // ときだけ最小化に倒し、タスクバー / ウィンドウ一覧に残して必ず復帰
      // できるようにする（#757・B 案 + ホスト検出）。
      if (await _linuxTrayHostAvailable()) {
        await windowManager.hide();
      } else {
        await windowManager.minimize();
      }
      return;
    }
    await windowManager.hide();
    // hide の後に Dock から消す（メニューバーのみの常駐）。key window がある状態で
    // .accessory に移すと切替が効きにくいため hide → accessory の順を守る。
    await _setDockIconHidden(true);
  }

  // --- TrayListener ---

  @override
  void onTrayIconMouseDown() {
    // 左クリックでウィンドウ復帰（3 OS 共通）。macOS のメニューバーでも
    // tray_manager はメニューを自動表示せず leftMouseDown を Dart へ転送する
    // ため、Windows / Linux と同じ「左=復帰 / 右=メニュー」に揃う。
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case _kShow:
        _showWindow();
      case _kExit:
        // 明示終了。preventClose を解いてから destroy し、onWindowClose の
        // hide 分岐に吸われず確実にプロセスを終わらせる。setPreventClose は
        // プラットフォームチャネル越しの非同期呼び出しのため、await せずに
        // destroy すると解除が反映される前にウィンドウが閉じ、onWindowClose の
        // hide 分岐に吸われうる。_enabled=false ガードで救済されるが綱渡りなので
        // 解除完了を待ってから終了する (#763)。
        _enabled = false;
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
    }
  }

  static const _kShow = 'show';
  static const _kExit = 'exit';
}
