import 'dart:io';

import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/service/push_key_store.dart';
import 'package:capsicum/src/service/push_registration_service.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1215 の、NSE 用のアクセストークンの写しの不変条件を固定する。
///
/// - 写しは iOS の Misskey のアカウントにだけ置く（トークンを読めるプロセスを
///   増やす変更なので、4KB を超えている経路に限る）
/// - アカウント単位の [PushKeyStore.delete] で消える（ログアウト後に残さない）
/// - Dart が書くキーと、iOS の NSE（`PushKeyReader.readNseToken`）が読むキーの
///   綴りが一致する（ずれると NSE が黙って写しを見つけられず、汎用の文面のまま）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> store;

  setUp(() {
    store = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'write':
              store[key!] = args['value'] as String;
              return null;
            case 'read':
              return store[key!];
            case 'delete':
              store.remove(key!);
              return null;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  const account = AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example.com',
    username: 'alice',
  );

  group('PushKeyStore の NSE 用トークンの写し (#1215)', () {
    test('NSE が読むキーの綴りで書く', () async {
      await PushKeyStore.saveNseToken(account.toStorageKey(), 'token-a');
      expect(
        store['capsicum_push_nse_token_misskey://alice@misskey.example.com'],
        'token-a',
      );
      expect(
        await PushKeyStore.readNseToken(account.toStorageKey()),
        'token-a',
      );
    });

    test('アカウント単位の delete で鍵と一緒に消える', () async {
      await PushKeyStore.saveNseToken(account.toStorageKey(), 'token-a');
      await PushKeyStore.delete(account.toStorageKey());
      expect(await PushKeyStore.readNseToken(account.toStorageKey()), isNull);
      expect(store, isEmpty);
    });
  });

  group('写しを置く対象 (#1215)', () {
    test('iOS の Misskey だけ', () {
      expect(
        PushRegistrationService.shouldSaveNseToken(
          isIOS: true,
          type: BackendType.misskey,
        ),
        isTrue,
      );
      expect(
        PushRegistrationService.shouldSaveNseToken(
          isIOS: true,
          type: BackendType.mastodon,
        ),
        isFalse,
      );
      expect(
        PushRegistrationService.shouldSaveNseToken(
          isIOS: false,
          type: BackendType.misskey,
        ),
        isFalse,
      );
    });
  });

  group('iOS の NSE と綴りが揃っている (#1215)', () {
    // ⚠ cwd は packages/capsicum（flutter test の既定）。
    final swift = File(
      'ios/CapsicumNotificationService/PushKeyReader.swift',
    ).readAsStringSync();

    test(
      'PushKeyReader.readNseToken が nse_token スロットを misskey の prefix で読む',
      () {
        expect(swift, contains('static func readNseToken(account: String)'));
        expect(swift, contains('slot: "nse_token"'));
        expect(swift, contains(r'accountStorageKey: "misskey://\(account)"'));
      },
    );
  });
}
