import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// OAuth の認可を待つあいだ、Android にプロセスを凍結させないための口 (#1108)。
///
/// Android の OAuth は loopback 方式 (#276) で、`http://localhost:7099/oauth/callback`
/// を **capsicum 自身の `HttpServer`** で受ける。受けたあと `capsicumauth://complete`
/// へ飛ぶ HTML を返し、それを見たブラウザがアプリを前面に戻す。
///
/// ⚠⚠ **その HTML を返すのが capsicum 自身**なので、待っているあいだにキャッシュ
/// アプリ freezer に凍結されると返せない。カーネルは TCP 接続を受けてバッファに
/// 溜めるが、`accept()` も `read()` もアプリのコードなので 1 バイトも読めない。
/// ブラウザは応答を待ち続けて固まり、**承認したのに何も起きないように見える**。
/// ⚠ **裏に回ってから凍結までは実測 70 秒**（2026-09-09・Pixel 6a・他アプリを
/// 開く必要すら無い）。サーバーのログイン画面で ID とパスワードを打ち、2FA の
/// コードを入れれば普通に超える。
///
/// ⚠ **Android 以外では何もしない。**デスクトップに freezer は無く、iOS は
/// loopback を使わない（`ASWebAuthenticationSession` でカスタムスキームが確実に
/// 戻る）。
///
/// 実体は `OAuthKeepAliveService`（`shortService` 型の foreground service）で、
/// **約 3 分で OS に打ち切られる**。それを超えたときの挙動は #1108 以前と同じ
/// （手動でアプリに戻れば #1057 の経路でホームに着く）ので退行はしない。
class OAuthKeepAlive {
  const OAuthKeepAlive._();

  static const _channel = MethodChannel(
    'net.shrieker.capsicum/oauth_keepalive',
  );

  /// この経路が要るプラットフォームか。
  ///
  /// ⚠ UI 層に `Platform.isX` を直書きしない指針 (#650) に従い、判定はここに
  /// 閉じ込めて機能名で公開する。
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 認可待ちを開始する。
  ///
  /// ⚠⚠ **アプリがフォアグラウンドにいるあいだに呼ぶこと。**foreground service
  /// はバックグラウンドからは起動できないので、**ブラウザを開いた後では遅い**。
  ///
  /// 戻り値は「実際に keep-alive が上がったか」。端末が Android 12 未満なら
  /// freezer が無いので `false`（失敗ではない）。
  static Future<bool> start() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException catch (e) {
      // ⚠ **ここで例外を投げ上げないこと。**keep-alive はログインの本筋では
      // なく、上げられなくても #1108 以前と同じ挙動に落ちるだけ。上げ損ねた
      // ことでログインそのものを失敗させるほうが害が大きい。
      debugPrint('capsicum: oauth_keepalive: start failed: ${e.code}');
      return false;
    }
  }

  /// 認可待ちを終える。
  ///
  /// ⚠ **認可完了・中断・タイムアウトのいずれでも必ず呼ぶ。**通知が出しっぱなしに
  /// なるうえ、`shortService` は 3 分で OS に打ち切られるため、放置は無意味な
  /// 常駐にしかならない。
  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      debugPrint('capsicum: oauth_keepalive: stop failed: ${e.code}');
    }
  }
}
