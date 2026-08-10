import 'dart:io' show Platform;

import 'package:capsicum/src/service/notification_dedup_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #945: 起動中の二重通知 dedup を Windows でも配線する。
///
/// #933 は「両経路のトースト Tag を揃えて OS に畳ませる」方式だったが、実機で
/// 畳まれず 2 通出た。Tag が畳めても通知音の重複は残るため、macOS (#674) と同じ
/// 「先に出した方が勝つ」方式へ寄せた。ここでは Dart 側終端が
///
/// - `addEmitted` を native へ送ること（WebSocket 先着 → WNS 側を抑止）
/// - `onRemotePresented` を受けること（WNS 先着 → WebSocket 側を抑止）
///
/// を固定する。**macOS 専用の NSE 掃除 (#673) まで Windows へ広げていない**
/// ことも併せて固定する（native 側は NotImplemented を返す）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'net.shrieker.capsicum/notification_dedup';
  const channel = MethodChannel(channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // このチャネルが動くのは macOS / Windows だけ。CI はどちらでも回りうるので、
  // 「配線される OS かどうか」で期待値を切り替える。
  final wired = Platform.isMacOS || Platform.isWindows;

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('addEmitted は native へキーをそのまま渡す', () async {
    final dedup = NotificationDedupChannel(channel: channel);

    await dedup.addEmitted('pooza@misskey.delmulin.com|abc');

    if (wired) {
      expect(calls, hasLength(1));
      expect(calls.single.method, 'addEmitted');
      expect(calls.single.arguments, 'pooza@misskey.delmulin.com|abc');
    } else {
      // 配線されない OS では native を叩かない（MissingPluginException 待ちに
      // しない）。
      expect(calls, isEmpty);
    }
  });

  test('onRemotePresented を受けるとコールバックへキーが流れる', () async {
    final dedup = NotificationDedupChannel(channel: channel)..start();
    final received = <String>[];
    dedup.onRemotePresented = received.add;

    await messenger.handlePlatformMessage(
      channelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onRemotePresented', 'pooza@mstdn.b-shock.org|123'),
      ),
      (_) {},
    );

    expect(received, wired ? ['pooza@mstdn.b-shock.org|123'] : isEmpty);
  });

  test('NSE 掃除 (#673) は macOS 限定のまま', () async {
    final dedup = NotificationDedupChannel(channel: channel);

    await dedup.getDeliveredRemotes();
    await dedup.removeDelivered(const ['id1']);

    // Windows には NSE も配信済み通知の列挙 API も無いので、呼びに行かない。
    final methods = calls.map((c) => c.method).toSet();
    expect(methods.contains('getDeliveredRemotes'), Platform.isMacOS);
    expect(methods.contains('removeDelivered'), Platform.isMacOS);
  });

  test('native が例外を返しても addEmitted は投げない', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    final dedup = NotificationDedupChannel(channel: channel);

    // dedup が成立しないだけで、通知経路そのものは止めない。
    await expectLater(dedup.addEmitted('a@b|c'), completes);
  });
}
