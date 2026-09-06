import 'dart:io';

import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1064: `catch` の中の `ref.read` が、元の例外を潰して観測を消すのを止める。
///
/// ## 何が起きていたか
///
/// `reportOpFailure(account: ref.read(currentAccountProvider))` は、
/// **catch 節の中で `await` の後に `ref.read` する**形になっていた（~19 箇所）。
///
/// - `flutter_riverpod` の `_assertNotDisposed()` は **`assert` ではなく素の
///   `throw StateError`** なので、⚠ **release ビルドでも投げる**
/// - 投げるのは `reportOpFailure` へ入る**前**なので、⚠⚠ **StateError が元の
///   例外を潰して Sentry に何も上がらない**
///
/// → **「エラーが出ないのでうまくいっている」に見える観測性ギャップ。**
/// しかも消えるのは**失敗を最も観測したい場面**（重い操作の最中に画面を離れた）
/// に限られるので、母数の側からは異常に見えない。
///
/// ## ⚠ この検査が要る理由
///
/// 直したのは 50 箇所の**書き方**であって、構造ではない。**次に
/// `reportOpFailure` を呼ぶ人が `ref.read(currentAccountProvider)` と書いたら
/// 同じ穴が開く。**しかも**開いたことは症状に出ない**（報告が消えるだけ）ので、
/// 機械で止めるしかない。
void main() {
  group('挙動: dispose 済みでも投げない', () {
    late Ref captured;
    late ProviderContainer container;

    setUp(() {
      final probe = Provider<int>((ref) {
        captured = ref;
        return 1;
      });
      container = ProviderContainer();
      container.read(probe);
    });

    test('⚠ 素の ref.read は dispose 後に投げる（前提の確認）', () {
      container.dispose();
      // ⚠ **これが穴の原因。**ここが投げなくなったら #1064 の前提が変わって
      // いるので、この検査ごと見直す。
      expect(
        () => captured.read(currentAccountProvider),
        throwsA(isA<StateError>()),
        reason: '_assertNotDisposed は assert ではなく素の throw（release でも投げる）',
      );
    });

    test('accountForReport は dispose 後でも投げず null を返す', () {
      container.dispose();
      expect(captured.accountForReport, isNull);
    });

    test('生きている間は素の read と同じ値を返す', () {
      // アカウント未ログインの container なので両方 null。
      // ⚠ 見たいのは「握りつぶして常に null を返す実装になっていない」こと
      // ではなく、「生存中は素の read と一致する」こと。
      expect(captured.accountForReport, captured.read(currentAccountProvider));
      container.dispose();
    });
  });

  group('ソース検査: 書き方が戻らないこと', () {
    List<File> dartFiles() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('.g.dart'))
        .where((f) => !f.path.endsWith('.freezed.dart'))
        .toList();

    /// 拡張の宣言そのものが載っているファイル（doc に旧形が出てくる）。
    const declarationFile = 'lib/src/provider/account_manager_provider.dart';

    test('探索が空振りしていない', () {
      expect(dartFiles().length, greaterThan(50));
      expect(File(declarationFile).existsSync(), isTrue);

      // ⚠ **置き換え後の形が実在することを先に固定する。**ここが 0 だと、
      // 下の「旧形が無い」は「どちらも無い」で緑になる。
      final adopted = dartFiles()
          .where(
            (f) => maskComments(
              f.readAsStringSync(),
            ).contains('account: ref.accountForReport'),
          )
          .length;
      expect(
        adopted,
        greaterThan(10),
        reason: 'ref.accountForReport がどこにも無い。検査のアンカーが外れている (#1064)',
      );
    });

    test('reportOpFailure の account に ref.read を直接渡さない (#1064)', () {
      final offenders = <String>[];
      for (final file in dartFiles()) {
        if (file.path == declarationFile) continue;
        final source = maskComments(file.readAsStringSync());
        if (source.contains('account: ref.read(currentAccountProvider)')) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'catch の中で ref.read すると、dispose 済みのとき StateError が元の'
            '例外を潰して Sentry に何も上がらない (#1064)。`ref.accountForReport` を'
            '使うか、await の前に account を捕まえて渡すこと'
            '\n${offenders.join('\n')}',
      );
    });

    test('拡張が WidgetRef と Ref の両方に生えている', () {
      // ⚠ provider 側（`Ref`）にも同じ形がある（autoDispose の破棄後に同じ
      // StateError を投げる）。片方だけ生やすと、もう片方が黙って旧形へ戻る。
      final source = maskComments(File(declarationFile).readAsStringSync());
      expect(source, contains('extension AccountForReport on WidgetRef'));
      expect(source, contains('extension AccountForReportOnRef on Ref'));
    });
  });
}
