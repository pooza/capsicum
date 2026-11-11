import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/clip_edit_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1050: クリップの作成 / 編集。項目は名前・説明・公開の 3 つ。
class _Adapter extends Mock
    implements DecentralizedBackendAdapter, ClipManagementSupport {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._account);

  final Account _account;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_account], current: _account);
}

void main() {
  late _Adapter adapter;

  setUpAll(() => registerFallbackValue(const ClipDraft(name: '')));

  setUp(() => adapter = _Adapter());

  /// 画面を開き、閉じたときの結果を [results] へ入れる。
  Future<List<Object?>> pump(WidgetTester tester, {NoteClip? clip}) async {
    final results = <Object?>[];
    final account = Account(
      key: const AccountKey(
        type: BackendType.misskey,
        host: 'misskey.example',
        username: 'me',
      ),
      adapter: adapter,
      user: const User(id: 'me', username: 'me'),
      userSecret: const UserSecret(accessToken: 'token'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(() => _AccountNotifier(account)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => results.add(
                  await Navigator.of(context).push<Object?>(
                    MaterialPageRoute(
                      builder: (_) => ClipEditScreen(clip: clip),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('作成は名前・説明・公開を送り、作ったクリップを返す', (tester) async {
    const created = NoteClip(id: 'new', name: '実況', isPublic: true);
    when(() => adapter.createClip(any())).thenAnswer((_) async => created);
    final results = await pump(tester);

    await tester.enterText(find.widgetWithText(TextField, '名前'), ' 実況 ');
    await tester.enterText(find.widgetWithText(TextField, '説明（任意）'), 'メモ');
    await tester.tap(find.text('公開'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final draft =
        verify(() => adapter.createClip(captureAny())).captured.single
            as ClipDraft;
    expect(draft.name, '実況');
    expect(draft.description, 'メモ');
    expect(draft.isPublic, isTrue);
    expect(results.single, same(created));
  });

  testWidgets('編集は今の値で始まり、保存すると true を返す', (tester) async {
    when(() => adapter.updateClip(any(), any())).thenAnswer((_) async {});
    final results = await pump(
      tester,
      clip: const NoteClip(
        id: 'c1',
        name: '実況',
        description: 'メモ',
        isPublic: true,
      ),
    );

    expect(find.text('クリップを編集'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final draft =
        verify(() => adapter.updateClip('c1', captureAny())).captured.single
            as ClipDraft;
    expect(draft.name, '実況');
    expect(draft.description, 'メモ');
    expect(draft.isPublic, isTrue);
    expect(results.single, isTrue);
  });

  testWidgets('名前が空なら送らない', (tester) async {
    await pump(tester);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    verifyNever(() => adapter.createClip(any()));
    expect(find.text('名前を入れてください'), findsOneWidget);
  });

  testWidgets('上限に当たったら、入力を残して知らせる', (tester) async {
    when(() => adapter.createClip(any())).thenThrow(const ClipLimitReached());
    final results = await pump(tester);

    await tester.enterText(find.widgetWithText(TextField, '名前'), '実況');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('このアカウントでは、これ以上クリップを作れません'), findsOneWidget);
    expect(find.text('実況'), findsOneWidget);
    expect(results, isEmpty, reason: '画面に留まる');
  });
}
