import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #975: 例外を Sentry へ流す経路を機械で守る。
///
/// `exception_scrub.dart` の doc は「生の例外を直接埋める形をリポジトリから
/// 無くす」と宣言しているが、#926 の置換は **1 行に収まっていた `debugPrint`
/// だけ**に当たっていた。改行をまたぐ形と、`captureException` へ生の例外を
/// 渡す形は残っていた。
///
/// ⚠⚠ **単一行の grep では 0 件に見える。**だから次も同じ取りこぼし方をする。
/// この検査は**ファイル全体を読んで括弧を数える**ので、引数が何行に分かれて
/// いても拾う。
///
/// ## なぜ優先度が高いか
///
/// release ビルドでは sentry_flutter が `debugPrint` を丸ごと breadcrumb 化
/// する。breadcrumb の `message` は `main.dart` の `_scrubBreadcrumb`（`data`
/// しか見ない）を通らないので、生の例外文字列がそのまま載る。さらに
/// `captureException` の `exceptions[].value` は **breadcrumb と違って必ず
/// 送られる**。
///
/// 今のところ実害が無いのは dio 5.9.x の
/// `defaultDioExceptionReadableStringBuilder` が URI を含まないからで、
/// **dio を上げた瞬間に無言で再発する**。
void main() {
  /// 検査対象。⚠ **capsicum パッケージだけでは足りない** — アダプタ側にも
  /// 同じ形が入りうるので、テストを 1 箇所に置いたまま隣のパッケージも読む。
  const roots = <String>[
    'lib',
    '../capsicum_core/lib',
    '../capsicum_backends/lib',
  ];

  /// 生の例外を渡してよい例外的な場所。**増やすときは理由を書くこと。**
  const allowedFiles = <String>{
    // scrub の実装そのもの。ここで scrubException を呼んだら無限再帰。
    'lib/src/util/exception_scrub.dart',
  };

  List<File> dartFiles() => [
    for (final root in roots)
      if (Directory(root).existsSync())
        ...Directory(root)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.endsWith('.g.dart'))
            .where((f) => !f.path.endsWith('.freezed.dart')),
  ];

  /// [open]（`(` の位置）に対応する閉じ括弧の index。見つからなければ -1。
  ///
  /// 文字列リテラルの中の括弧は数えない。⚠ **ここを雑にすると、`'('` を含む
  /// 文言で検査全体が静かに壊れる**（見逃しても誰も気づかない）。
  int matchParen(String s, int open) {
    var depth = 0;
    String? quote;
    for (var i = open; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// 引数リストを top-level のカンマで割る。
  List<String> splitArgs(String args) {
    final out = <String>[];
    var depth = 0;
    var start = 0;
    String? quote;
    for (var i = 0; i < args.length; i++) {
      final c = args[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') depth--;
      if (c == ',' && depth == 0) {
        out.add(args.substring(start, i).trim());
        start = i + 1;
      }
    }
    final tail = args.substring(start).trim();
    if (tail.isNotEmpty) out.add(tail);
    return out;
  }

  /// 呼び出しごとに `(引数リスト, 呼び出しの開始 index)` を返す。
  List<(String, int)> callsOf(String source, String name) {
    final out = <(String, int)>[];
    final pattern = RegExp('(?<![A-Za-z0-9_])$name\\s*\\(');
    for (final m in pattern.allMatches(source)) {
      final open = source.indexOf('(', m.start);
      final close = matchParen(source, open);
      if (close < 0) continue;
      out.add((source.substring(open + 1, close), m.start));
    }
    return out;
  }

  /// 個別に見逃す指示。**直前の行に書く。**
  ///
  /// ファイル単位の allowlist より狭く、grep で全件を数えられる形にしてある。
  /// ⚠ **理由を同じ行に書くこと**（`// $marker: <理由>`）。理由の無い抑止は
  /// レビューで落とす。
  const marker = 'scrub-guard: allow';

  /// [start] の呼び出しに [marker] が付いているか。直前の非空行だけを見る
  /// ので、離れた場所のコメントが効いてしまうことはない。
  bool isMarked(String source, int start) {
    final head = source.substring(0, start);
    final lines = head.split('\n');
    // 末尾は呼び出し自身の行頭（インデントのみ）。その手前へさかのぼる。
    for (var i = lines.length - 2; i >= 0; i--) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      return line.startsWith('//') && line.contains(marker);
    }
    return false;
  }

  /// 捕捉した例外を素で埋めている補間を探す。
  ///
  /// ⚠ **`$entry` / `$expected` を拾わない**よう、識別子の切れ目まで見る。
  ///
  /// ⚠ **メンバーアクセスは中身で判断する。**`${e.type.name}`（dio の enum 名）
  /// や `${e.code}`（PlatformException のコード）は素性が分かっていて安全な
  /// ので通す。危ないのは**オブジェクトを丸ごと**（`$e` / `${e}`）と、上流の
  /// 生データを引く経路（`.message` / `.data` / `.toString()` / `.uri` 等）。
  ///
  /// StackTrace は対象外。コード位置しか持たず、[debugLogException] 自身も
  /// 素通しする前提で作ってある。
  final interpolationStart = RegExp(
    r'\$\{?(e|err|error|ex|exception)(?![A-Za-z0-9_])',
  );
  final unsafeMembers = RegExp(
    r'\b(message|data|body|uri|path|toString|requestOptions)\b',
  );

  /// [args] の中の危ない補間を返す。
  List<String> unsafeInterpolations(String args) {
    final found = <String>[];
    for (final m in interpolationStart.allMatches(args)) {
      final after = args.substring(m.end);
      if (!after.startsWith('.') && !after.startsWith('?.')) {
        // `$e` / `${e}` — オブジェクトを丸ごと埋めている。
        found.add(m.group(0)!);
        continue;
      }
      // メンバーアクセス。補間の終端（`}` か、識別子・`.`・`?` の切れ目）まで見る。
      final chainMatch = RegExp(r'^[A-Za-z0-9_.?\[\]]*').firstMatch(after)!;
      final chain = chainMatch.group(0)!;
      if (unsafeMembers.hasMatch(chain)) found.add('${m.group(0)}$chain');
    }
    return found;
  }

  String relativePath(File f) =>
      f.path.replaceFirst('${Directory.current.path}/', '');

  test('captureException には scrub 済みの例外だけを渡す', () {
    final offenders = <String>[];
    for (final file in dartFiles()) {
      final path = relativePath(file);
      if (allowedFiles.contains(path)) continue;
      final source = file.readAsStringSync();
      for (final (args, start) in callsOf(source, 'captureException')) {
        final first = splitArgs(args).firstOrNull;
        if (first == null || first.isEmpty) continue;
        if (isMarked(source, start)) continue;
        // scrub 済み / その場で作った合成エラー（`StateError('...')` 等）は可。
        if (first.startsWith('scrubException(')) continue;
        // 直前で `final scrubbed = scrubException(e);` と控えた変数も可。
        // ⚠ **名前だけで信じる**ので、`scrubbed` を別の意味に使わないこと。
        if (RegExp(r'^scrubbed[A-Za-z0-9_]*$').hasMatch(first)) continue;
        if (RegExp(r'^[A-Z][A-Za-z0-9_]*\(').hasMatch(first)) continue;
        offenders.add('$path: captureException($first, ...)');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'exceptions[].value は breadcrumb と違って必ず送られる。'
          'scrubException(e) を通すこと\n${offenders.join('\n')}',
    );
  });

  /// breadcrumb になりうるログ経路。⚠ **`debugPrint` だけでは足りない** —
  /// `main.dart` の `_logDev` のような**薄いラッパー**を経由すると、名前だけ
  /// 見ている検査はすり抜ける（#975 の再発はここから起きた）。ラッパーが
  /// 増えていないことは下の「ラッパーが増えていない」テストで担保する。
  const breadcrumbSinks = <String>['debugPrint', '_logDev'];

  test('ログ経路に捕捉した例外を埋めない（scrub 済みを渡す）', () {
    final offenders = <String>[];
    for (final file in dartFiles()) {
      final path = relativePath(file);
      if (allowedFiles.contains(path)) continue;
      final source = file.readAsStringSync();
      for (final sink in breadcrumbSinks) {
        for (final (args, start) in callsOf(source, sink)) {
          final unsafe = unsafeInterpolations(args);
          if (unsafe.isEmpty) continue;
          if (isMarked(source, start)) continue;
          offenders.add('$path: $sink → ${unsafe.join(' / ')}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'sentry_flutter の DebugPrintIntegration は build mode で分岐せず'
          '登録される。breadcrumb の message は _scrubBreadcrumb（data しか'
          '見ない）を通らないので、debugLogException / _logDevException を'
          '使うこと\n${offenders.join('\n')}',
    );
  });

  /// [breadcrumbSinks] の網羅性を守る。**新しいラッパーが増えると、上の検査は
  /// 何も言わずに素通りする**（#975 の取りこぼしの正体がこれ）。
  ///
  /// 判定は「`debugPrint` に**文字列リテラル以外**を渡しているか」。素の
  /// `debugPrint('...')` は呼び出し側なので通し、`debugPrint(message)` の形＝
  /// 受け取った値をそのまま流す関数＝ラッパーだけを拾う。
  test('debugPrint のラッパーが増えていない', () {
    /// 既知のラッパー。**増やすときは [breadcrumbSinks] にも足すこと。**
    const known = <String>{
      // scrubException を通してから流す、推奨の経路。
      'lib/src/util/exception_scrub.dart',
      // release で no-op にする `_logDev` / `_logDevException`。
      'lib/main.dart',
    };
    final wrappers = <String>[];
    for (final file in dartFiles()) {
      final path = relativePath(file);
      if (known.contains(path)) continue;
      final source = file.readAsStringSync();
      for (final (args, _) in callsOf(source, 'debugPrint')) {
        final first = splitArgs(args).firstOrNull;
        if (first == null || first.isEmpty) continue;
        if (first.startsWith("'") || first.startsWith('"')) continue;
        wrappers.add('$path: debugPrint($first)');
      }
    }
    expect(
      wrappers,
      isEmpty,
      reason:
          'debugPrint を包む関数を足したら breadcrumbSinks にも追加すること。'
          '足さないと、そのラッパー越しの生例外を検査が見逃す\n'
          '${wrappers.join('\n')}',
    );
  });

  /// 検査そのものが空振りしていないことを見る。**ここが 0 だと、上の 2 つは
  /// 何も読まずに緑になる**（roots の相対パスがずれた等）。
  test('検査が実際にソースを読んでいる', () {
    final files = dartFiles();
    expect(files.length, greaterThan(100), reason: '対象ファイルが少なすぎる');
    final total = files.fold<int>(
      0,
      (n, f) => n + callsOf(f.readAsStringSync(), 'captureException').length,
    );
    expect(total, greaterThan(10), reason: 'captureException を 1 つも見つけられていない');
  });

  /// 括弧の対応付けが文字列リテラルに騙されないこと。ここが壊れると、上の
  /// 検査は静かに見逃す側へ倒れる。
  test('文字列リテラル中の括弧を数えない', () {
    const source = "debugPrint('a) b', \$e);";
    final calls = callsOf(source, 'debugPrint');
    expect(calls, hasLength(1));
    expect(calls.first.$1, "'a) b', \$e");
  });

  /// 見逃し指示が**直前の行だけ**に効くこと。効く範囲が広いと、無関係な
  /// コメントで後続の違反まで黙る。
  test('scrub-guard の marker は直前の行にだけ効く', () {
    const marked = '// $marker: 理由\n  debugPrint(\$e);';
    expect(isMarked(marked, marked.indexOf('debugPrint')), isTrue);

    const distant = '// $marker: 理由\n  foo();\n  debugPrint(\$e);';
    expect(isMarked(distant, distant.indexOf('debugPrint')), isFalse);
  });
}
