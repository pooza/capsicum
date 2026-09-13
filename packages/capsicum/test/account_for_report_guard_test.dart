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
/// `account:` の直後に素の `ref.read` を渡している形 (#1117-D)。
///
/// ⚠ **完全一致で見ていた**ので、`account:` と `ref.read` の間の改行や空白、
/// `currentAccountProvider` の内側の空白で素通りしていた。`dart format` の改行位置
/// は行の長さで変わるので、**完全一致は「たまたま当たっていた」に近い**。
final directRead = RegExp(
  r'account:\s*ref\s*\.\s*read\s*\(\s*currentAccountProvider\s*\)',
);

/// 素の `ref.read(currentAccountProvider)`（渡し方は問わない）。
final rawRead = RegExp(r'ref\s*\.\s*read\s*\(\s*currentAccountProvider\s*\)');

/// `catch` 節の本体（`{ … }` の中）を取り出す。
///
/// ⚠ **コメントを潰したソースを渡すこと。**本体に `// … }` があると括弧の対応が
/// 狂う（`support/dart_source.dart` の doc と同じ罠）。
///
/// ⚠ 入れ子のブロックは本体に含める（`if (mounted) { … }` の中で読んでいても
/// 潰れる形は同じ）。
List<String> catchBodies(String code) {
  final out = <String>[];
  for (final m in RegExp(r'catch\s*\([^)]*\)\s*\{').allMatches(code)) {
    var depth = 1;
    final start = m.end;
    var i = start;
    while (i < code.length && depth > 0) {
      final c = code[i];
      if (c == '{') depth++;
      if (c == '}') depth--;
      i++;
    }
    out.add(code.substring(start, i > start ? i - 1 : start));
  }
  return out;
}

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
        if (directRead.hasMatch(source)) offenders.add(file.path);
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

    // ⚠⚠ **こちらが本命 (#1117-D)。**上の検査は「`account:` の直後に書いてある」
    // 形しか見ないので、**一度変数で受ければ素通り**した:
    //
    // ```dart
    // } catch (e) {
    //   final account = ref.read(currentAccountProvider); // ← 素通りしていた
    //   reportOpFailure(account: account, …);
    // }
    // ```
    //
    // 潰れるのは `ref.read` の時点なので、**catch の中で読んでいること自体**が穴。
    // 渡し方ではなく読む場所を見る。
    test('⚠⚠ catch の中で currentAccountProvider を読まない (#1064 / #1117-D)', () {
      final offenders = <String>[];
      for (final file in dartFiles()) {
        if (file.path == declarationFile) continue;
        final source = maskComments(file.readAsStringSync());
        for (final body in catchBodies(source)) {
          if (rawRead.hasMatch(body)) {
            offenders.add(file.path);
            break;
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'catch の中の ref.read は dispose 済みで StateError を投げ、元の例外を'
            '潰す (#1064)。`ref.accountForReport` を使うか、try の前に捕まえること'
            '\n${offenders.join('\n')}',
      );
    });

    group('走査に歯がある（合成したソースで確かめる）', () {
      test('⚠ 空白・改行違いの直接渡しを拾う', () {
        // 旧実装は完全一致だったので、この 3 つを取りこぼしていた。
        for (final source in const [
          'reportOpFailure(account: ref.read(currentAccountProvider));',
          'reportOpFailure(account:  ref.read( currentAccountProvider ));',
          'reportOpFailure(\n  account:\n      ref.read(currentAccountProvider),\n);',
        ]) {
          expect(directRead.hasMatch(source), isTrue, reason: source);
        }
      });

      test('⚠⚠ 一度変数で受ける形を catch の中で拾う', () {
        const source = '''
try {
  await doSomething();
} catch (e) {
  final account = ref.read(currentAccountProvider);
  reportOpFailure(account: account, tagKey: 'chat.op');
}
''';

        expect(directRead.hasMatch(source), isFalse, reason: '直接渡しではない');
        expect(
          catchBodies(source).any(rawRead.hasMatch),
          isTrue,
          reason: 'catch の中で読んでいる＝潰れる形',
        );
      });

      test('try の中（catch の外）の読みは拾わない', () {
        const source = '''
try {
  final account = ref.read(currentAccountProvider);
  await doSomething(account);
} catch (e) {
  reportOpFailure(account: ref.accountForReport, tagKey: 'chat.op');
}
''';

        expect(catchBodies(source).any(rawRead.hasMatch), isFalse);
      });

      test('⚠ catch の中の入れ子ブロックも本体として見る', () {
        const source = '''
} catch (e) {
  if (mounted) {
    final account = ref.read(currentAccountProvider);
  }
}
''';

        expect(catchBodies(source).any(rawRead.hasMatch), isTrue);
      });

      test('on 型つきの catch も拾う', () {
        const source = '''
} on DioException catch (e, st) {
  final account = ref.read(currentAccountProvider);
}
''';

        expect(catchBodies(source).any(rawRead.hasMatch), isTrue);
      });
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
