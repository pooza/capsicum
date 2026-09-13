import 'package:capsicum/src/platform/oauth_keep_alive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1117-A: 認可待ち keep-alive の停止条件と、例外の握り方。
///
/// ⚠⚠ **`Platform.isAndroid` で分岐する機能なので、「Android のふり」をしないと
/// テストが分岐を一度も踏まない**（v1.64 の #1113 で踏んだ教訓）。ここは
/// `debugIsSupportedOverride` で開ける。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('net.shrieker.capsicum/oauth_keepalive');
  final calls = <String>[];
  Object? Function(MethodCall call)? handler;

  setUp(() {
    calls.clear();
    handler = (call) => call.method == 'start' ? true : null;
    OAuthKeepAlive.debugIsSupportedOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return handler!(call);
        });
  });

  tearDown(() {
    OAuthKeepAlive.debugIsSupportedOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start は active を返し、stop はそのセッションで止まる', () async {
    final session = await OAuthKeepAlive.start();

    expect(session.active, isTrue);

    await OAuthKeepAlive.stop(session);

    expect(calls, ['start', 'stop']);
  });

  // ⚠⚠ **null は「何もしない」側。**keep-alive を一度も上げていない画面の
  // dispose が、走っている別の試行の keep-alive を止める経路だった。
  test('⚠⚠ stop(null) は何もしない', () async {
    await OAuthKeepAlive.start();
    calls.clear();

    await OAuthKeepAlive.stop(null);

    expect(calls, isEmpty);
  });

  // ⚠ 世代ガード（a4d86f64）。1 本目の後片づけが 2 本目を止めない。
  test('⚠ 古いセッションでは止まらない', () async {
    final first = await OAuthKeepAlive.start();
    await OAuthKeepAlive.start();
    calls.clear();

    await OAuthKeepAlive.stop(first);

    expect(calls, isEmpty);
  });

  test('新しいセッションなら止まる', () async {
    await OAuthKeepAlive.start();
    final second = await OAuthKeepAlive.start();
    calls.clear();

    await OAuthKeepAlive.stop(second);

    expect(calls, ['stop']);
  });

  group('例外を投げ上げない', () {
    // ⚠⚠ **PlatformException だけ捕まえるのでは足りない。**plugin 未登録では
    // MissingPluginException が飛び、あちらは PlatformException の仲間ではない。
    // 投げ上げると呼び出し側の finally が切れ、ポート 7099 の解放が落ちる。
    test('⚠⚠ start の MissingPluginException は握る', () async {
      handler = (_) => throw MissingPluginException('no plugin');

      final session = await OAuthKeepAlive.start();

      expect(session.active, isFalse, reason: '上げられなかっただけで失敗ではない');
    });

    test('⚠⚠ stop の MissingPluginException は握る', () async {
      final session = await OAuthKeepAlive.start();
      handler = (_) => throw MissingPluginException('no plugin');

      await expectLater(OAuthKeepAlive.stop(session), completes);
    });

    test('start の PlatformException は握る', () async {
      handler = (_) => throw PlatformException(code: 'fgs_denied');

      final session = await OAuthKeepAlive.start();

      expect(session.active, isFalse);
    });

    test('stop の PlatformException は握る', () async {
      final session = await OAuthKeepAlive.start();
      handler = (_) => throw PlatformException(code: 'boom');

      await expectLater(OAuthKeepAlive.stop(session), completes);
    });
  });

  test('対象外のプラットフォームでは channel を叩かない', () async {
    OAuthKeepAlive.debugIsSupportedOverride = false;

    final session = await OAuthKeepAlive.start();
    await OAuthKeepAlive.stop(session);

    expect(session.active, isFalse);
    expect(calls, isEmpty);
  });
}
