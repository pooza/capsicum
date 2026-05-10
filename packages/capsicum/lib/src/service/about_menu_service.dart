import 'package:flutter/services.dart';

import '../router.dart';
import '../ui/util/about_dialog.dart';

/// macOS メニューバー「About capsicum」からの呼び出しを受けて Flutter 側
/// About ダイアログ（Drawer の「capsicum について」と同じもの）を開く。
///
/// ネイティブ側 (AppDelegate.showAboutDialog → AboutMenuPlugin.requestShowAbout)
/// が `showAbout` メソッドを invoke する。
class AboutMenuService {
  static const _channel = MethodChannel('net.shrieker.capsicum/about');

  static void initialize() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  static Future<dynamic> _handleMethod(MethodCall call) async {
    if (call.method == 'showAbout') {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null) {
        await showAboutCapsicum(ctx);
      }
    }
  }
}
