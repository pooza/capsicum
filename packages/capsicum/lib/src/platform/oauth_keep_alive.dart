import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../util/exception_scrub.dart';
import 'platform_info.dart';

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

  /// 認可待ちの世代。
  ///
  /// ⚠⚠ **keep-alive はプロセスに 1 つしか無いのに、ログイン試行は重なりうる。**
  /// #620 の silent recovery や二重タップで 2 本目が始まると、**1 本目の後片づけ
  /// （`finally` / `dispose`）が 2 本目の keep-alive を止めてしまう**。実機で
  /// 踏んだ（2026-09-09・08:04:34 と 08:05:21 に二重起動）。
  ///
  /// 既存の `HttpServer` 側が `identical(_oauthServer, server)` で同じ罠を
  /// 塞いでいるので、それに合わせる。
  static int _generation = 0;

  /// この経路が要るプラットフォームか。
  ///
  /// ⚠ UI 層に `Platform.isX` を直書きしない指針 (#650) に従い、判定は
  /// `platform_info` に集めて機能名で公開する。⚠⚠ **ここで
  /// `Platform.isAndroid` を書き直さない (#1117-E)** —— 以前はそうしていたため、
  /// `oauthCallbackNeedsAppReturn` と**同じ述語が 2 箇所**にあり、差し替え口も
  /// 別々だった（テストが本番では作れない組み合わせを作れる）。
  static bool get isSupported => needsOAuthKeepAlive;

  /// 認可待ちを開始する。
  ///
  /// ⚠⚠ **アプリがフォアグラウンドにいるあいだに呼ぶこと。**foreground service
  /// はバックグラウンドからは起動できないので、**ブラウザを開いた後では遅い**。
  ///
  /// 戻り値は [stop] に渡すためのセッション。⚠ **捨てないこと** —— 世代が
  /// 分からなくなると、古い試行が新しい試行の keep-alive を止める。
  static Future<OAuthKeepAliveSession> start() async {
    final token = ++_generation;
    if (!isSupported) {
      return OAuthKeepAliveSession._(token: token, active: false);
    }
    try {
      final active = await _channel.invokeMethod<bool>('start') ?? false;
      return OAuthKeepAliveSession._(token: token, active: active);
    } catch (e) {
      // ⚠ **ここで例外を投げ上げないこと。**keep-alive はログインの本筋では
      // なく、上げられなくても #1108 以前と同じ挙動に落ちるだけ。上げ損ねた
      // ことでログインそのものを失敗させるほうが害が大きい。
      //
      // ⚠⚠ **`PlatformException` だけを捕まえるのでは足りない (#1117-A)。**
      // plugin が未登録の環境では `MissingPluginException` が飛び、あちらは
      // `PlatformException` の仲間ではないので素通りする。素通りすると
      // `_authenticateViaLocalhostServer` の bind まで到達せず、**ポート 7099 を
      // 掴んだまま / 掴む前に**ログインが落ちる。型を絞る意味が無い場所。
      debugLogException('capsicum: oauth_keepalive: start failed', e);
      _reportStartFailureOnce(e is PlatformException ? e.code : 'unknown');
      return OAuthKeepAliveSession._(token: token, active: false);
    }
  }

  static bool _startFailureReported = false;

  /// 起動の失敗を Sentry へ 1 プロセス 1 回だけ送る（v1.64 のリリース前
  /// レビュー）。
  ///
  /// ⚠ **breadcrumb だけでは届かない。**Android 14 以降の foreground service の
  /// 起動失敗（型の不一致・バックグラウンドからの起動）は Play の用途申告とも
  /// 絡み、いちばん観測したい失敗なのに、別のイベントが送られない限り Sentry に
  /// 出なかった。⚠ 載せるのはエラーコードだけ（message は OS の文言）。
  static void _reportStartFailureOnce(String code) {
    if (_startFailureReported) return;
    _startFailureReported = true;
    try {
      // scrub-guard: allow: code は PlatformException のエラーコード（固定の識別子）
      Sentry.captureMessage(
        'oauth_keepalive.start_failed',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('phase', 'oauth_keepalive');
          scope.setTag('oauth_keepalive_code', code);
        },
      );
    } catch (_) {
      // Sentry の失敗でログインを止めない。
    }
  }

  /// 認可待ちを終える。
  ///
  /// ⚠ **認可完了・中断・タイムアウトのいずれでも必ず呼ぶ。**通知が出しっぱなしに
  /// なるうえ、`shortService` は 3 分で OS に打ち切られるため、放置は無意味な
  /// 常駐にしかならない。
  ///
  /// ⚠⚠ **[start] が返したセッションを渡すこと。**世代が進んでいたら（＝別の
  /// ログイン試行が始まっていたら）何もしない。渡さないと、**古い試行の後片づけ
  /// が新しい試行の keep-alive を止め、3 分打ち切りの案内通知まで消す**。
  /// ⚠⚠ **null を渡したら何もしない (#1117-A)。**以前は「世代が分からないので
  /// 無条件に止める」側へ倒していたが、**keep-alive を一度も上げていない画面の
  /// `dispose` が、走っている別の試行の keep-alive を止める**経路になっていた
  /// （`_keepAlive` は上げるまで null）。⚠ **止めたい相手が居るなら、その
  /// セッションを持っているはず**という形に寄せる。
  static Future<void> stop(OAuthKeepAliveSession? session) async {
    if (!isSupported) return;
    if (session == null) return;
    if (session.token != _generation) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      // ⚠ [start] と同じ理由で型を絞らない (#1117-A)。⚠⚠ **ここで投げ上げると
      // 呼び出し側の `finally` が途中で切れ、ポート 7099 の解放や案内通知の
      // 掃除が落ちる**（`MissingPluginException` で実際にその順序になる）。
      debugLogException('capsicum: oauth_keepalive: stop failed', e);
    }
  }
}

/// [OAuthKeepAlive.start] が返す 1 回ぶんの認可待ち。
class OAuthKeepAliveSession {
  const OAuthKeepAliveSession._({required this.token, required this.active});

  /// 何本目の認可待ちか。[OAuthKeepAlive.stop] の世代判定に使う。
  final int token;

  /// 実際に keep-alive が上がったか。
  ///
  /// Android 12 未満は freezer が無いので `false` になるが、**失敗ではない**。
  final bool active;
}
