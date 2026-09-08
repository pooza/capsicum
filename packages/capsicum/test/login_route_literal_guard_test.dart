import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1057: `/login` へは [loginLocation] 経由でしか遷移させない。
///
/// ⚠⚠ **引数を `extra` で渡すと、`refreshListenable` が鳴った瞬間に丸ごと
/// 落ちる。**go_router は refresh のたびに RouteMatchList をシリアライズ経由で
/// 組み直し、`extraCodec` が無いと `json.encoder.convert(extra)` に掛ける。
/// `BackendType`（enum）は JSON にできないので extra は null になり、`/login`
/// のフォールバックが `/server` へ飛ばして、**OAuth の完走を待っている
/// `LoginScreen` をその場で dispose する**。実機で再現済み（#1057）。
///
/// リテラルを直書きさせないことで、この形が戻ってくる経路を塞ぐ。組み立てと
/// 読み取りは `router.dart` の [loginLocation] / [resolveLoginArgs] に 1 対で
/// 置いてあり、往復は `router_login_args_test` が固定している。
void main() {
  final libDir = Directory('lib');
  final sources = libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  /// `/login` を文字列リテラルで書いている行を返す。
  ///
  /// ⚠ **コメントは潰す**（`// '/login' へ push する` のような説明で当たると、
  /// 直しようがないので検査ごと外されてしまう）。文字列リテラルは潰さない
  /// —— ここで探しているものそのものだから。
  List<String> offendersIn(String source) {
    final masked = maskComments(source);
    final pattern = RegExp('''['"]/login(?:[?'"]|\\\$)''');
    final hits = <String>[];
    final lines = masked.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) hits.add('${i + 1}: ${lines[i].trim()}');
    }
    return hits;
  }

  group('⚠ 走査が空振りしていない', () {
    test('lib の走査が実際にファイルを拾っている', () {
      expect(sources.length, greaterThan(100));
    });

    test('正本（router.dart）は実際に当たる', () {
      // ⚠ これが当たらなくなったら、パターンが実物の書き方から外れている。
      final router = File('lib/src/router.dart').readAsStringSync();
      expect(offendersIn(router), isNotEmpty);
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('直書きの遷移は当たる', () {
      const samples = [
        "context.push('/login', extra: {'host': host});",
        'context.go("/login");',
        "context.push('/login?host=example.com&backend=misskey');",
        "GoRoute(path: '/login', builder: (c, s) => const SizedBox());",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isNotEmpty, reason: sample);
      }
    });

    test('当ててはいけない形は当たらない', () {
      const samples = [
        // ヘルパー経由（これが正しい書き方）
        'context.push(loginLocation(args));',
        // コメントでの言及
        "// '/login' は loginLocation で組む",
        "/// `'/login'` へは直接飛ばさない",
        // 別のパス
        "context.go('/logins');",
        "context.go('/login_history');",
        // 変数名にたまたま含まれる
        'final loginLocationForTest = loginLocation(args);',
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isEmpty, reason: sample);
      }
    });
  });

  group('⚠⚠ 歯があることを実物で確かめる', () {
    test('修正前の server_selection_screen は当たる', () {
      // ⚠ **合成ソースだけでは足りない (docs/CLAUDE.md「ソース検査ガードの
      // 書き方」)。**自分が想定した書き方しか並べないので、実物の形を外して
      // いても緑になる。修正前のファイルそのものを食わせる。
      //
      // ⚠⚠ **SHA で固定する。**`HEAD:` で書くと、修正がコミットされた瞬間に
      // 取り出されるのが**修正後**のファイルになり、当たらなくなる（実際に
      // 赤にした）。ここで欲しいのは「歯が立つ実物」＝ `/login` を直書きして
      // いた最後のコミットなので、動かない参照でなければ意味が無い。
      // `c80318b4` = #1057 の 1 つ前の直し方。`analyze.yml` は
      // `fetch-depth: 0` なので CI でも引ける。
      final before = Process.runSync('git', [
        'show',
        'c80318b4:packages/capsicum/lib/src/ui/screen/server_selection_screen.dart',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      final source = before.stdout as String;
      expect(
        source,
        contains('backendType'),
        reason: '取り出したのが本当に修正前のファイルであること',
      );
      expect(
        offendersIn(source),
        isNotEmpty,
        reason: '修正前は /login を直書きしていたので、当たらなければ歯が無い',
      );
    });
  });

  test('lib に /login の直書きは router.dart だけ', () {
    final offenders = <String>[];
    for (final file in sources) {
      if (file.path.endsWith('src/router.dart')) continue;
      for (final hit in offendersIn(file.readAsStringSync())) {
        offenders.add('${file.path} $hit');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '/login への遷移は loginLocation() で組むこと (#1057)。'
          'extra に enum を積むと refresh で落ちて /server へ跳ね返される',
    );
  });
}
