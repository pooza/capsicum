import 'package:capsicum/src/provider/windows_store_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1248: Windows の製品版で、Store への商品の問い合わせが 1 回も返らなかった。
///
/// ⚠⚠ **Windows は内部ベータを配らないので、確かめられるのは製品版だけ。**
/// ネイティブが「どこで止まったか」を返し、それを毎回 Sentry へ送ることで、
/// 1 回の出荷で切り分けが進むようにしてある。ここではその受け渡しを固定する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('capsicum/store_iap');

  void mockQuery(Object? Function() reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'queryProducts');
          return reply();
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('windowsStoreProbeDiagnostics', () {
    test('返った回: 段階・件数・かかった時間を載せる', () {
      final d = windowsStoreProbeDiagnostics({
        'isStoreVersion': true,
        'stage': 'ok',
        'hresult': 0,
        'elapsedMs': 812,
        'associatedCount': 3,
      }, matchedCount: 3);
      expect(d, {
        'stage': 'ok',
        'is_store_version': true,
        'matched_count': 3,
        'elapsed_ms': 812,
        'associated_count': 3,
      });
    });

    test('HRESULT は負の int で届くので、符号なしの 16 進へ直す', () {
      // 0x803F6107 を int32 として読んだ値。
      final d = windowsStoreProbeDiagnostics({
        'isStoreVersion': false,
        'stage': 'extended_error',
        'hresult': -2143330041,
        'elapsedMs': 40,
      }, matchedCount: 0);
      expect(d['hresult'], '0x803F6107');
      expect(d['stage'], 'extended_error');
      expect(d.containsKey('associated_count'), isFalse);
    });

    test('段階を返さない古いネイティブは unknown、null は no_reply', () {
      expect(
        windowsStoreProbeDiagnostics({
          'isStoreVersion': false,
          'products': <Object>[],
        }, matchedCount: 0)['stage'],
        'unknown',
      );
      expect(
        windowsStoreProbeDiagnostics(null, matchedCount: 0)['stage'],
        'no_reply',
      );
    });
  });

  group('WindowsStoreBackend', () {
    test('時間切れで返った回は「利用不可」にし、段階を送る', () async {
      mockQuery(
        () => {
          'isStoreVersion': false,
          'products': <Object>[],
          'stage': 'timeout',
          'hresult': 0,
          'elapsedMs': 10003,
        },
      );
      final probes = <Map<String, Object>>[];
      final backend = WindowsStoreBackend(onProbe: probes.add);
      addTearDown(backend.dispose);

      expect(await backend.isAvailable(), isFalse);
      expect(probes, hasLength(1));
      expect(probes.single['stage'], 'timeout');
      expect(probes.single['elapsed_ms'], 10003);
    });

    test('⚠ 成功した回も送る（直ったことを「記録が無い」で読まない）', () async {
      mockQuery(
        () => {
          'isStoreVersion': true,
          'stage': 'ok',
          'hresult': 0,
          'elapsedMs': 650,
          'associatedCount': 3,
          'products': [
            {
              'productId': 'supporter.tip.small',
              'storeId': '9AAA',
              'title': 'ちょこっとサポート',
              'description': '',
              'formattedPrice': '¥120',
            },
          ],
        },
      );
      final probes = <Map<String, Object>>[];
      final backend = WindowsStoreBackend(onProbe: probes.add);
      addTearDown(backend.dispose);

      expect(await backend.isAvailable(), isTrue);
      final products = await backend.queryProducts({'supporter.tip.small'});
      expect(products.single.price, '¥120');
      // ⚠ isAvailable の結果を queryProducts が使い回すので、問い合わせは 1 回。
      expect(probes, hasLength(1));
      expect(probes.single['stage'], 'ok');
      // 紐づく add-on は 3 つあるのに 1 つしか合っていない ＝ SKU の綴りの線を読める。
      expect(probes.single['associated_count'], 3);
      expect(probes.single['matched_count'], 1);
    });

    test('ネイティブが null を返した回は no_reply', () async {
      mockQuery(() => null);
      final probes = <Map<String, Object>>[];
      final backend = WindowsStoreBackend(onProbe: probes.add);
      addTearDown(backend.dispose);

      expect(await backend.isAvailable(), isFalse);
      expect(probes.single['stage'], 'no_reply');
    });
  });
}
