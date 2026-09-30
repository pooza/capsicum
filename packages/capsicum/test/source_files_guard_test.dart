import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1168: ソース検査ガードのパス照合を Windows でも成立させる。
///
/// ## 何が起きていたか
///
/// Windows 機（x64・Flutter 3.44.6）で `flutter test` を回すと、ソース検査ガードが
/// **6 件落ちていた**（CI の Linux と macOS では緑）。`Directory(...).listSync()` が
/// 返すパスの区切りが `\` なのに、除外リスト・「綴りを持ってよい唯一の場所」の
/// 指定はどれも `/` 区切りのリテラルなので、**照合が外れて許可されているはずの
/// ファイルが違反扱いになる**。
///
/// ⚠⚠ **逆向きの穴のほうが危ない。**「このファイルを必ず走査している」系の固定を
/// `/` 区切りで書いていると、Windows では**空振りしても緑になる**
/// （`expect(offenders, isEmpty)` は何も見ていなくても通る）。落ちた 6 件は
/// 気付けたが、こちらは誰も気付けない。
///
/// ## この検査が見るもの
///
/// `docs/CLAUDE.md`「ソース検査ガードの書き方」の 3 点セットに沿う。
///
/// 1. 走査が空振りしていないこと（`lib` を実際に読めている・件数・既知のファイル）
/// 2. 判定（[posixPath]）に合成パスを直接食わせる
/// 3. ⚠⚠ **歯があること** —— Windows で実際に挙がったパスを除外リストへ当て、
///    **正規化しないと外れる**ことを固定する
///
/// さらに、**列挙を迂回して `Directory(...).listSync()` を直に書き足せない**ことも
/// 見る（ヘルパーへ寄せても、次に足すガードが素で書けば同じ穴が開く）。
void main() {
  group('判定ロジック: パスの正規化 (#1168)', () {
    test('Windows の区切りを / へ倒す', () {
      expect(
        posixPath(r'lib\src\ui\screen\templates_manage_screen.dart'),
        'lib/src/ui/screen/templates_manage_screen.dart',
      );
    });

    test('区切りが混在したパスも倒す', () {
      // ⚠ #1168 の実測値。`lib/src/ui\util\fediverse_link.dart` のように
      // `/` と `\` が混ざって出ていたので、「Windows なら」で分岐できない。
      expect(
        posixPath(r'lib/src/ui\util\fediverse_link.dart'),
        'lib/src/ui/util/fediverse_link.dart',
      );
    });

    test('すでに / のパスは触らない', () {
      const path = 'lib/src/service/fcm_service.dart';
      expect(posixPath(path), path);
    });
  });

  group('⚠⚠ 歯があること: 正規化しないと照合が外れる (#1168)', () {
    /// Windows 機で違反として挙がった実測値（#1168 の表）。
    const observed = <String>[
      r'lib\src\ui\screen\templates_manage_screen.dart',
      r'lib\src\provider\is_cat_provider.dart',
      r'lib/src/ui\util\fediverse_link.dart',
    ];

    /// 同じファイルを指す、ガードが持っている側の綴り。
    const allowed = <String>{
      'lib/src/ui/screen/templates_manage_screen.dart',
      'lib/src/provider/is_cat_provider.dart',
      'lib/src/ui/util/fediverse_link.dart',
    };

    test('正規化前は 1 件も当たらない（これが症状そのもの）', () {
      for (final path in observed) {
        expect(
          allowed.contains(path),
          isFalse,
          reason:
              '$path が除外リストに当たってしまう。'
              'この検査は「当たらないこと」を症状として固定している',
        );
      }
    });

    test('正規化すれば全件当たる', () {
      for (final path in observed) {
        expect(
          allowed.contains(posixPath(path)),
          isTrue,
          reason: '$path を正規化しても除外リストに当たらない',
        );
      }
    });

    test('照合相手のファイルが実在する', () {
      // ⚠ 綴りが古いと、上の 2 本は「当たる / 当たらない」だけを見て緑のまま
      // 意味を失う。
      for (final path in allowed) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '$path が無い。移動したならこの検査の実測値も直す',
        );
      }
    });
  });

  group('走査が空振りしていない', () {
    test('lib を読めていて、返るパスに \\ が無い', () {
      final files = sourceFiles('lib');
      expect(files.length, greaterThan(50), reason: 'lib を読めていない');
      expect(
        files.map((f) => f.path),
        contains('lib/src/service/fcm_service.dart'),
        reason: '既知のファイルが列挙に入っていない',
      );
      // ⚠ `r'\'` と書かない（[maskComments] が生文字列の `\` をエスケープとして
      // 読むので、このファイル自身の masking が以降ずれる）。
      expect(
        files.where((f) => f.path.contains('\\')),
        isEmpty,
        reason: '区切りが正規化されていない (#1168)',
      );
      // ⚠ 正規化したパスで**実際に開ける**こと。`/` のままでも Windows の
      // API は開けるので、呼び出し側は返ってきたパスをそのまま使える。
      expect(files.first.readAsStringSync(), isNotEmpty);
    });

    test('サブディレクトリも見ている', () {
      // #1061 の穴（非再帰で `settings/` の 8 画面が黙って消えていた）。
      expect(
        sourceFiles(
          'lib',
        ).where((f) => f.path.startsWith('lib/src/ui/screen/settings/')),
        isNotEmpty,
      );
    });

    test('recursive: false は直下だけ', () {
      final files = sourceFiles('lib', recursive: false);
      expect(files.map((f) => f.path), contains('lib/main.dart'));
      expect(files.where((f) => f.path.startsWith('lib/src/')), isEmpty);
    });

    test('extension の指定が効く', () {
      expect(
        sourceFiles('test', extension: '_test.dart').length,
        greaterThan(50),
      );
      expect(
        sourceFiles('test', extension: '_test.dart').map((f) => f.path),
        isNot(contains('test/support/source_files.dart')),
      );
    });
  });

  /// ⚠ **`lib` には生成物が 1 件も無い**（このパッケージの `.g.dart` /
  /// `.freezed.dart` は他のパッケージ側にある）ので、絞り込みの判定は実物では
  /// 確かめられない。合成したディレクトリを食わせる。
  group('合成したディレクトリで列挙を直接見る', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('source_files_guard');
      File('${root.path}/a.dart').writeAsStringSync('// a');
      File('${root.path}/b.g.dart').writeAsStringSync('// b');
      File('${root.path}/c.freezed.dart').writeAsStringSync('// c');
      File('${root.path}/d.md').writeAsStringSync('# d');
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/e.dart').writeAsStringSync('// e');
    });

    tearDown(() => root.deleteSync(recursive: true));

    /// 列挙結果を、合成ディレクトリからの相対パスで返す。
    /// ⚠ 比較の左右をそろえるため、根のほうも正規化する（Windows の
    /// `C:\Users\…\Temp\…` は列挙側だけ `/` になる）。
    Iterable<String> relative(List<File> files) =>
        files.map((f) => f.path.substring(posixPath(root.path).length + 1));

    test('.dart を再帰で拾い、パス順に返す', () {
      expect(relative(sourceFiles(root.path)), [
        'a.dart',
        'b.g.dart',
        'c.freezed.dart',
        'sub/e.dart',
      ]);
    });

    test('skipGenerated が外すのは生成物だけ', () {
      expect(relative(sourceFiles(root.path, skipGenerated: true)), [
        'a.dart',
        'sub/e.dart',
      ]);
    });

    test('recursive: false は直下だけ', () {
      expect(relative(sourceFiles(root.path, recursive: false)), [
        'a.dart',
        'b.g.dart',
        'c.freezed.dart',
      ]);
    });

    test('extension を差し替えられる', () {
      expect(relative(sourceFiles(root.path, extension: '.md')), ['d.md']);
    });

    test('返るパスに \\ が混ざらない', () {
      expect(
        sourceFiles(root.path).where((f) => f.path.contains('\\')),
        isEmpty,
      );
    });
  });

  group('列挙はヘルパーへ寄せる (#1168)', () {
    const helper = 'test/support/source_files.dart';

    test('test 配下で Directory(...).listSync を直に書かない', () {
      final offenders = <String>[];
      for (final file in sourceFiles('test')) {
        if (file.path == helper) continue;
        // ⚠ コメントと文字列を潰してから見る。doc で `listSync()` に言及して
        // いる行（`bottom_inset_guard_test` の #1061 の説明）を拾わない。
        final code = maskStrings(maskComments(file.readAsStringSync()));
        if (code.contains('.listSync(')) offenders.add(file.path);
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'ファイルの列挙は $helper の sourceFiles() を通すこと。'
            '素の listSync は Windows で `\\` 区切りのパスを返し、'
            '除外リストとの照合が外れる (#1168)'
            '\n${offenders.join('\n')}',
      );
    });

    test('⚠ 探している綴りが実物と合っている', () {
      // 「`.listSync(` が無い」だけを見ると、綴りを間違えていても緑になる。
      expect(
        maskStrings(maskComments(File(helper).readAsStringSync())),
        contains('.listSync('),
        reason: '$helper が列挙をやめた。この検査の綴りも直す',
      );
    });
  });
}
