import 'dart:io';

import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/secret_service_probe.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1085: secure storage に**触る前に** Secret Service が応答するか聞く。
///
/// ## ⚠⚠ なぜ「読み取りの上限」では足りなかったか
///
/// `flutter_secure_storage_linux` はメソッドチャネルのハンドラの中で
/// `secret_password_lookupv_sync` を直に呼ぶ（3.0.2 でも同じ）。ハンドラが走るのは
/// **プラットフォームスレッド**＝ GTK のメインループ＝**フレームを提示する
/// スレッド**なので、Secret Service が応答しないとそこが止まる。
///
/// → **`kSecureStorageReadTimeout` は発火する**（Sentry に
/// `secure_storage.timeout` が届いた）**のに、旗を立てても描くスレッドが居ない
/// ので画面は真っ黒のまま。**2026-09-09 に報告者の環境で実測。
///
/// ⚠ **「タイムアウトを入れた」で直ったことにしない。**この Issue は 1 度
/// 「直した」と判断して動作確認を依頼し、直っていなかった。
void main() {
  setUp(SecretServiceProbe.resetForTest);
  tearDown(() {
    SecretServiceProbe.resetForTest();
    debugSecretServiceOverride = null;
  });

  group('Secret Service を使わない OS', () {
    test('確かめずに true を返す（相手が居ない）', () async {
      debugSecretServiceOverride = false;
      var called = false;
      SecretServiceProbe.debugProbeOverride = () async {
        called = true;
        return false;
      };

      expect(await SecretServiceProbe.isResponsive(), isTrue);
      expect(
        called,
        isFalse,
        reason:
            'Apple の Keychain / Android の Keystore / Windows の DPAPI は '
            'D-Bus を経由しない。聞く相手が居ないので確かめてはいけない',
      );
    });
  });

  group('Secret Service を使う OS', () {
    setUp(() => debugSecretServiceOverride = true);

    test('応答すれば true', () async {
      SecretServiceProbe.debugProbeOverride = () async => true;
      expect(await SecretServiceProbe.isResponsive(), isTrue);
    });

    test('⚠ 応答しなければ false（触らせない）', () async {
      SecretServiceProbe.debugProbeOverride = () async => false;
      expect(await SecretServiceProbe.isResponsive(), isFalse);
    });

    test('⚠ 1 プロセス 1 回しか聞かない', () async {
      // ⚠ **毎回聞くと、応答しない環境で読み取りのたびに待ちが増える。**
      // アカウントの数だけ 800ms を払うことになる。
      var calls = 0;
      SecretServiceProbe.debugProbeOverride = () async {
        calls++;
        return false;
      };

      await SecretServiceProbe.isResponsive();
      await SecretServiceProbe.isResponsive();
      await SecretServiceProbe.isResponsive();

      expect(calls, 1);
    });

    test('⚠ false へ倒れたら true へ戻さない', () async {
      var result = false;
      SecretServiceProbe.debugProbeOverride = () async => result;
      expect(await SecretServiceProbe.isResponsive(), isFalse);

      // 復旧したかを知るには実際に触るしかなく、それが「触ると固まる」入口。
      result = true;
      expect(
        await SecretServiceProbe.isResponsive(),
        isFalse,
        reason: 'プロセスを跨がないので、再起動すれば消える',
      );
    });
  });

  /// ⚠⚠ **上の挙動テストは override 経由なので、既定の実装が逆でも全部緑になる。**
  /// #1104 で確立した「override 無しで既定値そのものを踏む」を、ここでも置く。
  group('既定値（override 無し）', () {
    test('この OS の判定が Platform と一致する', () {
      expect(usesSecretService, Platform.isLinux);
    });

    test('Secret Service を使わない OS なら、実際に聞かずに true', () async {
      // ⚠ macOS / Windows の CI ではここが本物の経路を踏む（D-Bus は無い）。
      if (Platform.isLinux) return;
      expect(await SecretServiceProbe.isResponsive(), isTrue);
    });
  });

  /// ⚠⚠ **順序が逆だと意味が無い。**「触ってから上限で打ち切る」では、
  /// 打ち切った時点で既にプラットフォームスレッドが止まっている。
  group('ソース検査: 触る前に聞いていること', () {
    const path = 'lib/src/service/account_storage.dart';

    test('探索が空振りしていない', () {
      expect(File(path).existsSync(), isTrue);
      final code = maskComments(File(path).readAsStringSync());
      expect(
        code,
        contains('_storage.read('),
        reason: '読み取りの呼び出しを拾えていない。検査のアンカーが外れている',
      );
    });

    test('_read は probe を通ってから _storage.read を呼ぶ', () {
      final code = maskComments(File(path).readAsStringSync());
      final probe = code.indexOf('SecretServiceProbe.isResponsive()');
      final read = code.indexOf('_storage.read(');

      expect(
        probe,
        isNot(-1),
        reason:
            'secure storage を触る前の疎通確認が消えている (#1085)。'
            '読み取りの上限だけでは、プラットフォームスレッドが塞がるので'
            '画面が真っ黒のまま復帰しない',
      );
      expect(read, isNot(-1));
      expect(
        probe,
        lessThan(read),
        reason:
            '疎通確認が読み取りより後にある。触った時点で固まるので、'
            '後から確かめても手遅れ',
      );
    });

    test('⚠ 応答しないときは null ではなく TimeoutException を投げる', () {
      // ⚠ **null に潰すと「secret が存在しない」と区別がつかずログアウト扱い。**
      // #1085 のコメントで明示された制約で、probe 経路でも同じ。
      final code = maskComments(File(path).readAsStringSync());
      final probe = code.indexOf('SecretServiceProbe.isResponsive()');
      final tail = code.substring(probe);
      expect(
        tail.indexOf('throw TimeoutException') <
            tail.indexOf('return _storage.read('),
        isTrue,
        reason: 'probe が false のときに投げていない。null を返すとアカウントが消える',
      );
    });
  });

  /// ⚠⚠ **手元で緑・CI で赤になるテストを増やさない (2026-09-11)。**
  ///
  /// `secure_storage_timeout_test` の 2 件が実際にそうなった。`usesSecretService`
  /// は **Linux でだけ true** なので、
  ///
  /// - **macOS / Windows の手元** — probe を素通りして通る
  /// - **Linux の CI** — 本物の D-Bus 疎通を試みる。⚠ **`fakeAsync` の中では実
  ///   I/O が進まない**ので `_probeTimeout` の**タイマーだけ**が `elapse` で
  ///   発火し、**読み取りの上限より先に**打ち切られて赤くなる
  ///
  /// ⚠ **手元では一度も再現しないので、原因にたどり着くまでが遠い。**
  /// `fakeAsync` の中で `AccountStorage` を触るテストは、**probe を差し替える**
  /// こと（[SecretServiceProbe.debugProbeOverride]）を機械で要求する。
  group('ソース検査: fakeAsync × AccountStorage は probe を差し替える', () {
    /// 差し替えが要るテストか。
    ///
    /// ⚠ **「要る」の条件は 2 つそろったとき**。`AccountStorage` を素の
    /// `async` で使うぶんには実 I/O が進むので、この罠は踏まない。
    bool needsProbeStub(String code) =>
        code.contains('fakeAsync(') && code.contains('AccountStorage(');

    bool hasProbeStub(String code) =>
        code.contains('SecretServiceProbe.debugProbeOverride');

    List<File> testFiles() => Directory('test')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('_test.dart'))
        .toList();

    test('探索が空振りしていない', () {
      final files = testFiles();
      expect(
        files.length,
        greaterThan(100),
        reason: 'test/ を舐められていない。走査が空なら下の検査は常に緑になる',
      );
      // ⚠ **既知の対象が母数に入っていること。**ここが外れると「該当 0 件」で
      // 素通りする。
      expect(
        files
            .map((f) => f.path)
            .where((p) => p.contains('secure_storage_timeout')),
        isNotEmpty,
      );
    });

    test('判定そのものが当たる（合成ソース）', () {
      expect(
        needsProbeStub('fakeAsync((async) { AccountStorage(s); });'),
        isTrue,
      );
      // 片方だけなら要らない。
      expect(needsProbeStub('fakeAsync((async) {});'), isFalse);
      expect(needsProbeStub('AccountStorage(s).getSecrets(k);'), isFalse);
      expect(
        hasProbeStub('SecretServiceProbe.debugProbeOverride = f;'),
        isTrue,
      );
      expect(hasProbeStub('SecretServiceProbe.resetForTest();'), isFalse);
    });

    test('⚠ 差し替えていないテストが無い', () {
      final offenders = <String>[];
      for (final file in testFiles()) {
        final code = maskComments(file.readAsStringSync());
        if (needsProbeStub(code) && !hasProbeStub(code)) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'fakeAsync の中で AccountStorage を触るのに probe を差し替えていない。'
            '⚠ **手元（macOS / Windows）では緑・Linux の CI で赤になる。**'
            'setUp で debugSecretServiceOverride と '
            'SecretServiceProbe.debugProbeOverride を立てること\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
