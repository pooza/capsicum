import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/secure_storage_health.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1104: **読み取りに失敗しただけで secret を消してはいけない。**
///
/// Linux で Secret Service（libsecret → gnome-keyring / kwalletd）が例外を
/// 返すと、`getSecrets` は `_isKeychainTransient`（`-25308` = Apple 専用）にも
/// `Platform.isAndroid` にも当たらず、**最後の else で `_storage.delete` に
/// 落ちていた**。一覧には「未接続」として残る (#967) が secret は本当に消えて
/// いるので、**キーリングが復旧しても戻らず再ログインが要る**。
///
/// ⚠⚠ **実発生している**（Sentry `CAPSICUM-53` / `release=capsicum@1.63.0+179`
/// / `os=Linux` / 2026-09-08）。
///
/// ⚠⚠ **このファイルの要点は「分岐の両側を踏むこと」。**#1085 で
/// `Platform.isIOS || Platform.isMacOS` を直書きしたら手元（macOS）で緑・
/// CI（Linux）で赤になった。**ローカルの全数テストはプラットフォーム分岐の
/// 検査にならない**ので、`debugMayDeleteSecretOnReadFailureOverride` で
/// 両側を固定する。
class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// 実際に観測された例外（Sentry `CAPSICUM-53` と同じ形）。
///
/// ⚠ **`code` は `Libsecret error` という粗い 1 種類**しか来ない。transient を
/// 名指しできないのが #1104 の根。
PlatformException _libsecretUnlockFailure() => PlatformException(
  code: 'Libsecret error',
  message: 'Failed to unlock the keyring',
);

void main() {
  setUp(SecureStorageHealth.resetForTest);

  tearDown(() {
    SecureStorageHealth.resetForTest();
    debugMayDeleteSecretOnReadFailureOverride = null;
    debugSecretServiceOverride = null;
  });

  group('permanent を判別できないプラットフォーム（Linux / Android / Windows）', () {
    setUp(() {
      debugMayDeleteSecretOnReadFailureOverride = false;
      debugSecretServiceOverride = true;
    });

    test('⚠ キーリングの解錠に失敗しても secret を消さない', () async {
      final storage = _MockSecureStorage();
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenThrow(_libsecretUnlockFailure());

      await expectLater(
        AccountStorage(storage).getSecrets('mastodon://alice@mstdn.example'),
        throwsA(isA<TransientSecretUnavailableException>()),
        reason:
            '⚠ **null を返してはいけない。**「secret が存在しない」と区別が'
            'つかずログアウト扱いになり、キーリングが復旧しても戻らない',
      );

      verifyNever(() => storage.delete(key: any(named: 'key')));
    });

    test('⚠ 読めなかったことを画面で言う（無言で「未接続」にしない）', () async {
      final storage = _MockSecureStorage();
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenThrow(_libsecretUnlockFailure());

      await AccountStorage(storage)
          .getSecrets('mastodon://bob@mstdn.example')
          .catchError((Object _) => null);

      expect(
        SecureStorageHealth.unavailable,
        isTrue,
        reason:
            '⚠ 真っ黒なウインドウを直しても、原因の分からない「未接続」に'
            '変わるだけでは #1085 の反省が活きない',
      );
    });

    test('⚠ Secret Service を使わない backend では案内を出さない', () async {
      // Android の Keystore 失敗で「キーリングが読めません」と出すと、
      // ユーザーは存在しないものを探すことになる。
      debugSecretServiceOverride = false;
      final storage = _MockSecureStorage();
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenThrow(PlatformException(code: 'BadPaddingException'));

      await AccountStorage(storage)
          .getSecrets('mastodon://carol@mstdn.example')
          .catchError((Object _) => null);

      expect(SecureStorageHealth.unavailable, isFalse);
    });

    test('⚠ PlatformException でラップされない失敗でも消さない（:199 側）', () async {
      // BadPaddingException 等は PlatformException を経由せずに来る。
      // **片方だけ直しても塞がらない**ので、こちらも固定する。
      final storage = _MockSecureStorage();
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenThrow(StateError('decrypt failed'));

      await expectLater(
        AccountStorage(storage).getSecrets('mastodon://dave@mstdn.example'),
        throwsA(isA<TransientSecretUnavailableException>()),
      );

      verifyNever(() => storage.delete(key: any(named: 'key')));
    });

    /// ⚠⚠ **読めたが中身が壊れている、は読み取りの失敗ではない**（v1.64 の
    /// リリース PR の Codex P2）。以前は `jsonDecode` の失敗も上の汎用 catch に
    /// 落ち、「一時的に読めない」として同じ壊れた値を読み直すだけの再試行を
    /// 永久に繰り返していた（Linux ではキーリングのせいにする案内まで出た）。
    test('⚠⚠ 中身が壊れていたら transient にしない（secret が無い扱い）', () async {
      final storage = _MockSecureStorage();
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenAnswer((_) async => '{"access_token": broken');

      final secrets = await AccountStorage(
        storage,
      ).getSecrets('mastodon://erin@mstdn.example');
      expect(secrets, isNull, reason: '再ログインへ回す（再ログインが上書きする）');
      expect(
        SecureStorageHealth.unavailable,
        isFalse,
        reason: '読めているのにキーリングのせいにしない',
      );
      verifyNever(() => storage.delete(key: any(named: 'key')));
    });
  });

  group('permanent を判別できるプラットフォーム（Apple）', () {
    setUp(() {
      debugMayDeleteSecretOnReadFailureOverride = true;
      debugSecretServiceOverride = false;
    });

    test('⚠ 従来どおり、判別できない失敗は permanent として消す', () async {
      // ⚠ **この歯が残っていることを確かめるのが目的。**#1104 の修正で
      // 「どこでも消さない」にしてしまうと、Apple で本当に壊れた item が
      // 残り続けて再ログインの導線が出なくなる。
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key'))).thenThrow(
        PlatformException(
          code: 'Unexpected security result code',
          message: 'Code: -25300, Message: Item not found.',
        ),
      );
      when(
        () => storage.delete(key: any(named: 'key')),
      ).thenAnswer((_) async {});

      final secrets = await AccountStorage(
        storage,
      ).getSecrets('mastodon://erin@mstdn.example');

      expect(secrets, isNull);
      verify(
        () => storage.delete(key: 'secret_mastodon://erin@mstdn.example'),
      ).called(1);
    });

    test('⚠ Keychain ロック (-25308) は Apple でも消さない（#531 の歯）', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key'))).thenThrow(
        PlatformException(
          code: 'Unexpected security result code',
          message:
              'Code: -25308, Message: User interaction is not allowed., -25308',
        ),
      );

      await expectLater(
        AccountStorage(storage).getSecrets('mastodon://frank@mstdn.example'),
        throwsA(isA<TransientSecretUnavailableException>()),
      );

      verifyNever(() => storage.delete(key: any(named: 'key')));
    });
  });

  group('⚠ 歯があることの確認（override 無しで既定値を踏む）', () {
    test('既定では CI (Linux) / 実機 Linux は「消さない」側に居る', () {
      // ⚠ **override を全部外して既定値そのものを見る。**override を渡す
      // テストだけだと、`mayDeleteSecretOnReadFailure` の**既定の実装が
      // 逆になっていても全部緑になる**。
      debugMayDeleteSecretOnReadFailureOverride = null;
      debugSecretServiceOverride = null;

      expect(
        mayDeleteSecretOnReadFailure,
        isFalse,
        reason:
            'テストは Linux (CI) / macOS (手元) の両方で走る。⚠ macOS で '
            'true になるのは正しいので、**この固定は Linux でしか意味を'
            '持たない** — CI が本番の検査',
        skip: !usesSecretServiceKeyring,
      );
      expect(secretStoreTag, 'libsecret', skip: !usesSecretServiceKeyring);
    });
  });
}
