import 'package:capsicum/src/service/announcement_subscription_service.dart';
import 'package:capsicum/src/service/push_device_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// relay に登録する device_type の導出 (#468 / #474 / #919)。
///
/// 綴りは relay の `case` 分岐のキーそのものなので、文字列まで固定する。
/// ホスト OS に依存しないよう、実プラットフォームではなくフラグで検証する。
String? _resolve({
  bool isWeb = false,
  bool isIOS = false,
  bool isAndroid = false,
  bool isMacOS = false,
  bool isWindows = false,
}) => resolvePushDeviceType(
  isWeb: isWeb,
  isIOS: isIOS,
  isAndroid: isAndroid,
  isMacOS: isMacOS,
  isWindows: isWindows,
);

void main() {
  group('resolvePushDeviceType', () {
    test('iOS は ios', () => expect(_resolve(isIOS: true), 'ios'));

    test(
      'Android は android',
      () => expect(_resolve(isAndroid: true), 'android'),
    );

    // macOS は iOS と同一 APNs Auth Key だが、relay 側の集計と配送分岐を
    // 分けるため別の device_type で登録する (#468)。
    test('macOS は ios ではなく macos', () {
      expect(_resolve(isMacOS: true), 'macos');
    });

    test(
      'Windows は windows',
      () => expect(_resolve(isWindows: true), 'windows'),
    );

    // ネイティブ push の経路が無い (#475)。登録自体を止める。
    test('Linux (どのフラグも立たない) は null', () => expect(_resolve(), isNull));

    // Platform.isXxx は Web で投げるため、呼び出し側が kIsWeb を先に見る。
    // ここでは「Web と分かっていれば他のフラグより優先して null」を固定する。
    test('Web は他のフラグより優先して null', () {
      expect(_resolve(isWeb: true, isIOS: true), isNull);
    });
  });

  group('お知らせ push の配送対象 (capsicum-relay#36)', () {
    // relay の AnnouncementWorker#deliver と 1 対 1。ここがずれると
    // 「登録できるのに届かない」か「届くのに購読できない」が生まれる。
    test('ios / android / macos / windows の 4 種', () {
      expect(AnnouncementSubscriptionService.deliverableDeviceTypes, {
        'ios',
        'android',
        'macos',
        'windows',
      });
    });

    // #919 の本体。relay#36 Phase 1 で macOS が配送対象に入った。
    test('macOS が含まれる', () {
      expect(
        AnnouncementSubscriptionService.deliverableDeviceTypes,
        contains(_resolve(isMacOS: true)),
      );
    });

    // #978 の本体。bg task が無暗号化 announcement を解釈できるようになった。
    // ⚠ 対になる relay#36 Phase 2 (`when 'windows'` + `announcement_body`) が
    // 未デプロイのうちは、購読行はできるが配送されない（壊れはしない）。
    test('Windows が含まれる', () {
      expect(
        AnnouncementSubscriptionService.deliverableDeviceTypes,
        contains(_resolve(isWindows: true)),
      );
    });

    test('Linux (null) は含まれない', () {
      expect(
        AnnouncementSubscriptionService.deliverableDeviceTypes,
        isNot(contains(_resolve())),
      );
    });
  });
}
