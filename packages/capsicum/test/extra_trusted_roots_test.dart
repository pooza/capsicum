import 'dart:convert';
import 'dart:io';

import 'package:capsicum/src/platform/extra_trusted_roots.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';

/// PEM 1 本の DER を取り出し、SHA-256 の指紋を `AA:BB:…` の形で返す。
String _fingerprint(String pem) {
  final body = pem
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  final digest = SHA256Digest().process(base64.decode(body));
  return digest
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// `main()` の本体だけを切り出す。見るのは呼び出しの順番だけなので、
/// 行コメント（`installExtraTrustedRoots` の説明に目印の語が出る）を落とせば足りる。
String _mainBody(String source) {
  final code = source
      .split('\n')
      .map((l) => l.trimLeft().startsWith('//') ? '' : l)
      .join('\n');
  final start = code.indexOf('Future<void> main() async {');
  expect(start, isNonNegative, reason: 'main() が見つからない');
  final end = code.indexOf('\n}\n', start);
  return code.substring(start, end);
}

/// [body] の中で、ルートを足す呼び出しが通信の始まりより前にあるか。
/// 違反があれば理由を返す。
List<String> _orderViolations(String body) {
  final install = body.indexOf('installExtraTrustedRoots(');
  if (install < 0) return ['installExtraTrustedRoots() を呼んでいない'];
  final violations = <String>[];
  for (final marker in ['SentryFlutter.init(', '_startApp(', 'Dio(']) {
    final at = body.indexOf(marker);
    if (at >= 0 && at < install) violations.add('$marker より後で呼んでいる');
  }
  return violations;
}

void main() {
  group('足す証明書 (#1298)', () {
    test('ISRG Root X1 / X2 の 2 本で、指紋が Let\'s Encrypt の公表値と一致する', () {
      expect(extraTrustedRootPems, hasLength(2));
      expect(extraTrustedRootPems.map(_fingerprint).toList(), [
        '96:BC:EC:06:26:49:76:F3:74:60:77:9A:CF:28:C5:A7:CF:E8:A3:C0:AA:E1:1A:8F:FC:EE:05:C0:BD:DF:08:C6',
        '69:72:9B:8E:15:A8:6E:FC:17:7A:57:AF:B7:17:1D:FC:64:AD:D2:8C:2F:CA:8C:F1:50:7E:34:45:3C:CB:14:70',
      ]);
    });

    test('⚠ 指紋の照合が空振りしていない: 1 文字変えると指紋が変わる', () {
      final tampered = extraTrustedRootPems.first.replaceFirst('MIIF', 'MIIG');
      expect(
        _fingerprint(tampered),
        isNot(_fingerprint(extraTrustedRootPems.first)),
      );
    });
  });

  group('installExtraTrustedRoots (#1298)', () {
    test('Windows 以外では何もしない', () {
      final ctx = SecurityContext(withTrustedRoots: false);
      expect(
        installExtraTrustedRoots(isWindows: false, context: ctx).status,
        ExtraTrustedRootsStatus.skipped,
      );
    });

    test('Windows では足せる（PEM が SecurityContext に読み込める）', () {
      final ctx = SecurityContext(withTrustedRoots: false);
      expect(
        installExtraTrustedRoots(isWindows: true, context: ctx).status,
        ExtraTrustedRootsStatus.installed,
      );
    });

    test('OS のルートに重ねて足しても例外にならない', () {
      final ctx = SecurityContext(withTrustedRoots: true);
      expect(
        installExtraTrustedRoots(isWindows: true, context: ctx).status,
        ExtraTrustedRootsStatus.installed,
      );
      // 2 回目（同じものの重ね足し）も通る
      expect(
        installExtraTrustedRoots(isWindows: true, context: ctx).status,
        ExtraTrustedRootsStatus.installed,
      );
    });

    // #1332。⚠ 以前は `catch (_)` で捨てていて、X1 だけ効いた回と区別できなかった。
    test('失敗したら、何本目で落ちたかと例外の型を残す', () {
      final ctx = SecurityContext(withTrustedRoots: false);
      final result = installExtraTrustedRoots(
        isWindows: true,
        context: ctx,
        pems: [
          extraTrustedRootPems.first,
          '-----BEGIN CERTIFICATE-----\nbroken\n-----END CERTIFICATE-----\n',
        ],
      );
      expect(result.status, ExtraTrustedRootsStatus.failed);
      expect(result.failedAt, 2);
      expect(result.errorType, isNotEmpty);
      expect(result.breadcrumbData, {
        'failed_at': 2,
        'error_type': result.errorType,
      });
    });

    test('成功・対象外では breadcrumb の data は空', () {
      final ctx = SecurityContext(withTrustedRoots: false);
      expect(
        installExtraTrustedRoots(isWindows: true, context: ctx).breadcrumbData,
        isEmpty,
      );
      expect(
        installExtraTrustedRoots(isWindows: false, context: ctx).breadcrumbData,
        isEmpty,
      );
    });
  });

  group('main() で通信より前に呼ぶ (#1298)', () {
    final source = File('lib/main.dart').readAsStringSync();

    test('実物の main() は、Sentry・Dio・アプリの起動より前で足している', () {
      expect(_orderViolations(_mainBody(source)), isEmpty);
    });

    test('⚠ 走査が空振りしていない: 見ている目印が main() に実在する', () {
      final body = _mainBody(source);
      expect(body, contains('installExtraTrustedRoots('));
      expect(body, contains('SentryFlutter.init('));
      expect(body, contains('_startApp('));
    });

    test('判定に合成ソースを食わせる', () {
      expect(
        _orderViolations('''
installExtraTrustedRoots();
await SentryFlutter.init((o) {}, appRunner: () => _startApp());
'''),
        isEmpty,
      );
      expect(
        _orderViolations('''
await SentryFlutter.init((o) {}, appRunner: () => _startApp());
installExtraTrustedRoots();
'''),
        hasLength(2),
      );
      expect(
        _orderViolations('final dio = Dio();\ninstallExtraTrustedRoots();'),
        ['Dio( より後で呼んでいる'],
      );
      expect(_orderViolations('await SentryFlutter.init((o) {});'), [
        'installExtraTrustedRoots() を呼んでいない',
      ]);
    });
  });
}
