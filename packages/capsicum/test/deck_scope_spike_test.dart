// #720 デッキ表示の設計スパイク（[docs/deck-ui-plan.md] 未決事項 7）の実測。
//
// 問い: **カラムを ProviderScope で包んで「現在のアカウント」を上書きすれば、
// UI 側 62 ファイルを書き換えずにカラムごとのアカウント解決ができるか。**
//
// 結果（2026-09-06・flutter_riverpod 2.6.1 で実測）: **できる。**
// しかも当初の想定と違い、宣言漏れは silent failure ではなく assert で落ちる。
//
// ⚠ **使い捨てのつもりで書いたが、残すことにした。**フェーズ 2 の設計全体が
// 「Riverpod のスコープ解決がこう振る舞う」という前提の上に乗るため、契約として
// 固定する（`account_manager_has_session_test.dart` と同じ扱い）。⚠ **Riverpod 3
// はスコープの規則を変えている**ので、上げるときにここが落ちて気づける。
//
// ⚠ **これは capsicum のコードを検査するテストではない。**デッキが未実装の
// 現時点では、pin しているのは外部ライブラリの契約だけ。フェーズ 2 に入ったら、
// 宣言漏れの網羅検査（走査テスト）は別途要る（3-b のコメントを参照）。

import 'package:capsicum/src/provider/account_manager_provider.dart' as real;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本物の `Account` の代役。検証したいのは Riverpod の解決規則なので、
/// アダプタを持つ実物ではなく識別できる最小の値で足りる。
class FakeAccount {
  final String label;
  const FakeAccount(this.label);
}

/// 本物の `currentAccountProvider` に対応する。カラムごとに上書きする対象。
final currentAccountProvider = Provider<FakeAccount>(
  (ref) => const FakeAccount('root'),
);

/// 本物の `currentAdapterProvider` に対応する（`dependencies` を宣言した版）。
final scopedAdapterProvider = Provider<String>(
  (ref) => 'adapter:${ref.watch(currentAccountProvider).label}',
  dependencies: [currentAccountProvider],
);

/// ⚠ 宣言漏れの対照群。現状の capsicum の書き方そのもの。
final unscopedAdapterProvider = Provider<String>(
  (ref) => 'adapter:${ref.watch(currentAccountProvider).label}',
);

/// 本線 TL に対応する AutoDisposeAsyncNotifier。スコープごとに別インスタンスに
/// なるか（＝カラムごとに独立した TL 状態を持てるか）を見る。
class SpikeTimelineNotifier extends AutoDisposeAsyncNotifier<String> {
  static int buildCount = 0;

  @override
  Future<String> build() async {
    buildCount++;
    final account = ref.watch(currentAccountProvider);
    return 'timeline(${account.label})';
  }
}

final spikeTimelineProvider =
    AsyncNotifierProvider.autoDispose<SpikeTimelineNotifier, String>(
      SpikeTimelineNotifier.new,
      dependencies: [currentAccountProvider],
    );

void main() {
  setUp(() => SpikeTimelineNotifier.buildCount = 0);

  group('#720 スパイク: ProviderContainer の入れ子スコープ', () {
    test('1. dependencies を宣言した派生 provider は、そのスコープの値を返す', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);

      final columnA = ProviderContainer(
        parent: root,
        overrides: [
          currentAccountProvider.overrideWithValue(const FakeAccount('A')),
        ],
      );
      addTearDown(columnA.dispose);

      final columnB = ProviderContainer(
        parent: root,
        overrides: [
          currentAccountProvider.overrideWithValue(const FakeAccount('B')),
        ],
      );
      addTearDown(columnB.dispose);

      // ここが成り立てば、UI 62 ファイルの `ref.read(currentAdapterProvider)` は
      // 書き換えずにカラムのアカウントで動く。
      expect(root.read(scopedAdapterProvider), 'adapter:root');
      expect(columnA.read(scopedAdapterProvider), 'adapter:A');
      expect(columnB.read(scopedAdapterProvider), 'adapter:B');
    });

    test('2. AutoDisposeAsyncNotifier はスコープごとに別インスタンスになる', () async {
      final root = ProviderContainer();
      addTearDown(root.dispose);

      final columnA = ProviderContainer(
        parent: root,
        overrides: [
          currentAccountProvider.overrideWithValue(const FakeAccount('A')),
        ],
      );
      addTearDown(columnA.dispose);

      final columnB = ProviderContainer(
        parent: root,
        overrides: [
          currentAccountProvider.overrideWithValue(const FakeAccount('B')),
        ],
      );
      addTearDown(columnB.dispose);

      expect(await columnA.read(spikeTimelineProvider.future), 'timeline(A)');
      expect(await columnB.read(spikeTimelineProvider.future), 'timeline(B)');

      // 別インスタンス = build が 2 回走っている。1 回なら共有されている。
      expect(SpikeTimelineNotifier.buildCount, 2);
    });

    test('3. dependencies の宣言漏れは、debug では assert で落ちる（silent ではない）', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);

      final columnB = ProviderContainer(
        parent: root,
        overrides: [
          currentAccountProvider.overrideWithValue(const FakeAccount('B')),
        ],
      );
      addTearDown(columnB.dispose);

      // 宣言した側は B を見る。
      expect(columnB.read(scopedAdapterProvider), 'adapter:B');

      // ⚠⚠ 当初は「黙ってルートの値を読む」と想定していたが、実測は違った。
      // Riverpod 2.6.1 は宣言漏れを検出して落とし、しかも直し方まで出す:
      //   "Tried to read ... from a place where one of its dependencies were
      //    overridden but the provider is not. To fix this error, you can add
      //    <dependency> to the "dependencies" of <provider>"
      expect(
        () => columnB.read(unscopedAdapterProvider),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.toString(),
            'message',
            contains('dependencies'),
          ),
        ),
      );
    });

    test('3-b. ⚠ ただし検出は assert 依存 = release では消える', () {
      // 検出の実体は container.dart:430 の `assert(() { ... }(), '')` ブロック
      // 丸ごと。release ビルドでは assert が落とされ、`reader.getElement()` が
      // **ルートスコープの element を返す** = 黙って「現在のアカウント」で動く。
      //
      // したがって:
      //   - 開発 / CI（debug で走る）では宣言漏れは自動的に大声で出る
      //   - **本番では出ない**ので、テストが 1 度も通らない経路は素通りする
      //
      // → 走査テストの役割は「唯一の検出手段」から「テストが踏まない経路の
      //    網羅保証」へ下がる。⚠ **不要にはならない**（capsicum の UI 62 ファイル
      //    を全部踏むテストは存在しない）。
      var assertsEnabled = false;
      assert(() {
        assertsEnabled = true;
        return true;
      }());

      // このテスト自体が debug で走っていることの確認。ここが false になる
      // 環境では上の 3 番は成立しない。
      expect(assertsEnabled, isTrue, reason: 'flutter test は debug 相当で走る前提');
    });
  });

  group('#720 スパイク: 実物の capsicum provider で確かめる', () {
    test('4. 実物の currentAccountProvider は overrideWithValue できる', () {
      // 仮の値でなく本物の provider を上書きできることの確認。Account の構築は
      // アダプタ一式が要るので、ここでは null を入れて「上書きが通る」ことだけ
      // 見る（値の出し分けは 1〜2 で確認済み）。
      final root = ProviderContainer();
      addTearDown(root.dispose);

      final column = ProviderContainer(
        parent: root,
        overrides: [real.currentAccountProvider.overrideWithValue(null)],
      );
      addTearDown(column.dispose);

      expect(column.read(real.currentAccountProvider), isNull);
    });

    test('5. ⚠ 実物の currentAdapterProvider は今のままではスコープに追随しない', () {
      // これがフェーズ 2 で足す必要のある宣言そのもの。現状の
      //   final currentAdapterProvider = Provider<...>((ref) =>
      //       ref.watch(currentAccountProvider)?.adapter);
      // には dependencies が無いので、スコープされた文脈から読むと落ちる。
      //
      // ⚠ **落ちること自体が良い知らせ。**「宣言を足し忘れた provider は
      // 黙って現在のアカウントで動く」ではなく「開発中に気づく」を意味する。
      final root = ProviderContainer();
      addTearDown(root.dispose);

      final column = ProviderContainer(
        parent: root,
        overrides: [real.currentAccountProvider.overrideWithValue(null)],
      );
      addTearDown(column.dispose);

      expect(
        () => column.read(real.currentAdapterProvider),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('#720 スパイク: ウィジェット階層の ProviderScope', () {
    testWidgets('カラムを ProviderScope で包めば、子孫は無改修でそのアカウントを見る', (tester) async {
      // 「UI 側のコードを 1 行も変えない」を再現するための子孫ウィジェット。
      // 本物の PostTile が `ref.read(currentAdapterProvider)` と書いているのと
      // 同じ形で、自分がどのスコープに居るかを知らない。
      Widget descendant() => Consumer(
        builder: (context, ref, _) => Text(
          ref.watch(scopedAdapterProvider),
          textDirection: TextDirection.ltr,
        ),
      );

      Widget column(String label) => ProviderScope(
        overrides: [
          currentAccountProvider.overrideWithValue(FakeAccount(label)),
        ],
        child: descendant(),
      );

      await tester.pumpWidget(
        ProviderScope(
          child: Row(
            textDirection: TextDirection.ltr,
            children: [column('A'), column('B')],
          ),
        ),
      );

      expect(find.text('adapter:A'), findsOneWidget);
      expect(find.text('adapter:B'), findsOneWidget);
    });
  });
}
