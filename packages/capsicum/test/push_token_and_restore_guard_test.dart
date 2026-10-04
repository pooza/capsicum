import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1223 / #1219: **プッシュが丸ごと死ぬ経路を無音にしない**ための不変条件。
///
/// 🔴 **2026-10-04 の Android 実機検証で、調査が行き止まりになった。**利用権は
/// `active` なのに `/register` へ一度も到達せず、再試行は「デバイストークンを
/// 取得できませんでした」から動かない。⚠⚠ **`getToken()` が null を返す経路が
/// `debugPrint` だけ**で、理由を推定で終わらせるしかなかった。
void main() {
  const fcmPath = 'lib/src/service/fcm_service.dart';
  const registrationPath = 'lib/src/service/push_registration_service.dart';
  const sectionPath =
      'lib/src/ui/widget/relay_entitlement_purchase_section.dart';
  const backendPath = 'lib/src/provider/supporter_purchase_backend.dart';
  const providerPath = 'lib/src/provider/supporter_purchase_provider.dart';

  /// この回より前の綴り（歯の確認）。⚠ **`HEAD` と書かない。**
  const beforeRev = 'a5d7affa';

  String read(String path) => maskComments(File(path).readAsStringSync());

  String before(String path) {
    final r = Process.runSync('git', [
      'show',
      '$beforeRev:packages/capsicum/$path',
    ], workingDirectory: '../..');
    expect(r.exitCode, 0, reason: (r.stderr as String));
    return maskComments(r.stdout as String);
  }

  // ---- 判定ロジック（合成ソースを食わせられる形） ----

  /// `getToken returned null` の分岐が Sentry へ報告しているか。
  ///
  /// ⚠ **分岐の中だけを見る。**ファイル全体で `captureException` の有無を見ると、
  /// 既に在る `catch` 側の報告に当たって**常に真**になる。
  bool reportsNullToken(String source) {
    const needle = "debugPrint('capsicum: push.fcm: getToken returned null')";
    final at = source.indexOf(needle);
    if (at < 0) return false;
    // 分岐の終わり（次の `}` が閉じるまで）を粗く切る。
    var depth = 1;
    var end = source.length;
    for (var i = at; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    final branch = source.substring(at, end);
    return branch.contains('Sentry.captureException') &&
        branch.contains("'token_null'");
  }

  /// `_registerAccountImpl` の本体を切り出す。
  ///
  /// ⚠⚠ **ファイル全体で綴りを探してはいけない。**`reconcileDeviceToken` が
  /// 同じ `_getDeviceToken() ?? await _waitForDeviceToken()` を**以前から持って
  /// いる**ので、全体で見ると**修正前でも真**になる（この検査を書いたときに
  /// 実際に空振りした）。
  String registerAccountImplBody(String source) {
    final m = RegExp(
      r'static Future<void> _registerAccountImpl\(',
    ).firstMatch(source);
    expect(m, isNotNull, reason: '_registerAccountImpl が無い。変えたならこの検査も直す');
    var paren = 1;
    var i = m!.end;
    for (; i < source.length && paren > 0; i++) {
      if (source[i] == '(') paren++;
      if (source[i] == ')') paren--;
    }
    final open = source.indexOf('{', i);
    expect(open, greaterThan(0));
    var depth = 0;
    for (var j = open; j < source.length; j++) {
      if (source[j] == '{') depth++;
      if (source[j] == '}') {
        depth--;
        if (depth == 0) return source.substring(open, j);
      }
    }
    fail('_registerAccountImpl の終端が見つからない');
  }

  /// 1 アカウントの登録が、トークンの到着を待つ形になっているか。
  bool retryWaitsForToken(String source) => registerAccountImplBody(
    source,
  ).contains('_getDeviceToken() ?? await _waitForDeviceToken()');

  // ---- 走査が空振りしていない ----

  group('⚠ 走査が空振りしていない', () {
    test('前提: 5 つのファイルが読めている', () {
      for (final path in [
        fcmPath,
        registrationPath,
        sectionPath,
        backendPath,
        providerPath,
      ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
        expect(read(path).length, greaterThan(500), reason: path);
      }
    });

    test('前提: 探している綴りが実物に在る', () {
      expect(
        read(fcmPath),
        contains("debugPrint('capsicum: push.fcm: getToken returned null')"),
      );
      expect(read(registrationPath), contains('_waitForDeviceToken'));
      // ⚠ 待ちの実装そのものが在ること（消えたら判定は常に偽になる）。
      expect(
        read(registrationPath),
        contains('static Future<String?> _waitForDeviceToken()'),
      );
    });
  });

  // ---- 判定に合成ソースを食わせる ----

  group('⚠ 判定に合成ソースを食わせる', () {
    const needle = "debugPrint('capsicum: push.fcm: getToken returned null')";

    test('報告のある分岐は通る', () {
      expect(
        reportsNullToken(
          "{ $needle; Sentry.captureException(x, withScope: (s) "
          "{ s.setTag('fcm.error', 'token_null'); }); }",
        ),
        isTrue,
      );
    });

    test('⚠⚠ debugPrint だけの分岐は検出する', () {
      expect(reportsNullToken('{ $needle; }'), isFalse);
    });

    test('⚠ 別の場所にある captureException を数えない', () {
      // catch 側だけが報告している形（これが元の状態）。
      expect(
        reportsNullToken(
          '{ $needle; } catch (e) { Sentry.captureException(e); }',
        ),
        isFalse,
      );
    });

    test('待ちの綴りが無ければ検出する', () {
      String synthetic(String line) =>
          'static Future<void> _registerAccountImpl(Account a, {bool e = true}) '
          '{ $line }';

      expect(
        retryWaitsForToken(synthetic('final t = _getDeviceToken();')),
        isFalse,
      );
      expect(
        retryWaitsForToken(
          synthetic(
            'final t = _getDeviceToken() ?? await _waitForDeviceToken();',
          ),
        ),
        isTrue,
      );
    });

    test('⚠⚠ 別メソッドの同じ綴りを数えない', () {
      // `reconcileDeviceToken` が以前から同じ綴りを持っている形。
      expect(
        retryWaitsForToken(
          'static Future<void> reconcileDeviceToken() '
          '{ final c = _getDeviceToken() ?? await _waitForDeviceToken(); } '
          'static Future<void> _registerAccountImpl(Account a, {bool e = true}) '
          '{ final t = _getDeviceToken(); }',
        ),
        isFalse,
      );
    });
  });

  // ---- 本物のソースに当てる ----

  group('配線（本物のソース）', () {
    test('🔴 getToken が null の回を Sentry へ報告する (#1223)', () {
      expect(reportsNullToken(read(fcmPath)), isTrue);
    });

    test('⚠ 権限の状態をタグに載せる（拒否と FCM 側の都合を分けるため）', () {
      expect(read(fcmPath), contains("'fcm.permission'"));
    });

    test('⚠⚠ 再試行もトークンの到着を待つ (#1223)', () {
      expect(retryWaitsForToken(read(registrationPath)), isTrue);
    });

    test('⚠ 利用権を取り直す口がある (#1219)', () {
      // backend → provider → UI の 3 層が揃っていること。
      expect(read(backendPath), contains('Future<void> restore()'));
      expect(read(providerPath), contains('Future<void> restoreEntitlement()'));
      expect(read(sectionPath), contains('restoreEntitlement()'));
      expect(read(sectionPath), contains("const Text('取り直す')"));
    });

    test('⚠⚠ 持っている人に購入ボタンを出さない（二重購入の防止は維持）', () {
      final source = read(sectionPath);
      final at = source.indexOf('state.hasEntitlement');
      expect(at, greaterThanOrEqualTo(0));

      // ⚠ 三項の**真の枝が先**に来るので、`取り直す` が `FilledButton`（価格の
      // ボタン＝偽の枝）より前に在ることで「持っている人には出さない」が立つ。
      // ⚠⚠ **固定幅の窓で切らない** —— コメントを伏せた空白が窓を食い潰して
      // 空振りした（この検査を書いたときに実際に踏んだ）。
      final restore = source.indexOf('取り直す', at);
      final buy = source.indexOf('FilledButton', at);
      expect(restore, greaterThanOrEqualTo(0));
      expect(buy, greaterThanOrEqualTo(0));
      expect(restore, lessThan(buy));
    });
  });

  // ---- 歯があることを、穴を開けて確かめる ----

  group('⚠⚠ 歯があることを、穴を開けて確かめる', () {
    test('前は getToken の null が無音だった', () {
      expect(reportsNullToken(before(fcmPath)), isFalse);
    });

    test('前は再試行がトークンを待たなかった', () {
      expect(retryWaitsForToken(before(registrationPath)), isFalse);
      // ⚠ 起動時の経路（registerAllAccounts）は当時も待っていた ——
      // **非対称だったことの確認**で、穴ではない。
      expect(before(registrationPath), contains('_waitForDeviceToken()'));
    });

    test('前は利用権を取り直す口が無かった', () {
      expect(before(backendPath), isNot(contains('Future<void> restore()')));
      expect(
        before(providerPath),
        isNot(contains('Future<void> restoreEntitlement()')),
      );
      expect(before(sectionPath), isNot(contains('取り直す')));
      // ⚠ 代わりに「利用中」の文字だけが出ていた（抜け道が無かった）。
      expect(before(sectionPath), contains("const Text('利用中')"));
    });
  });
}
