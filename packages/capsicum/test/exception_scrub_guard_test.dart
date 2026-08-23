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

  /// [open]（[openChar] の位置）に対応する閉じ括弧の index。見つからなければ -1。
  ///
  /// 文字列リテラルの中の括弧は数えない。⚠ **ここを雑にすると、`'('` を含む
  /// 文言で検査全体が静かに壊れる**（見逃しても誰も気づかない）。
  int matchBracket(String s, int open, String openChar, String closeChar) {
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
      if (c == openChar) depth++;
      if (c == closeChar) {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  int matchParen(String s, int open) => matchBracket(s, open, '(', ')');

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

  /// 名前の直後 [from] から、任意の型引数リストを読み飛ばして `(` の index を
  /// 返す。`(` に行き着かなければ -1。
  ///
  /// ⚠ **宣言と呼び出しの両方で要る（#1020・Codex P2 の 5 巡目）。**宣言側だけ
  /// `<…>` を読み飛ばすようにすると、`log<T>` は sink として見つかるのに
  /// **`log<Object>('failed: $e')` という呼び出しが見えない**という、いちばん
  /// たちの悪い形（検査は動いているのに素通り）になる。
  int parenAfter(String source, int from) {
    var i = from + RegExp(r'^\s*').firstMatch(source.substring(from))!.end;
    if (i < source.length && source[i] == '<') {
      final generics = matchBracket(source, i, '<', '>');
      if (generics < 0) return -1;
      i =
          generics +
          1 +
          RegExp(r'^\s*').firstMatch(source.substring(generics + 1))!.end;
    }
    if (i >= source.length || source[i] != '(') return -1;
    return i;
  }

  /// 呼び出しごとに `(引数リスト, 呼び出しの開始 index)` を返す。
  List<(String, int)> callsOf(String source, String name) {
    final out = <(String, int)>[];
    final pattern = RegExp('(?<![A-Za-z0-9_])$name(?![A-Za-z0-9_])');
    for (final m in pattern.allMatches(source)) {
      final open = parenAfter(source, m.end);
      if (open < 0) continue;
      final close = matchParen(source, open);
      if (close < 0) continue;
      out.add((source.substring(open + 1, close), m.start));
    }
    return out;
  }

  /// 関数宣言に見えるが違うもの。`if (…) {` は `名前(…) {` と同じ形。
  const notDeclarations = <String>{
    'if',
    'for',
    'while',
    'switch',
    'catch',
    'return',
    'do',
    'else',
    'assert',
    'await',
    'yield',
    'set',
    'get',
    'on',
    'when',
  };

  /// ソース中の関数 / メソッド宣言を `(名前, 仮引数, 本体の開始, 本体の終了)`
  /// で返す。本体は `{ … }` と `=> …;` の両方に対応する。
  ///
  /// ⚠ **総称型の宣言を落とさない（#1020・Codex P2 の 4 巡目）。**
  /// `void log<T>(String message)` は名前と `(` の間に型引数が挟まるので、
  /// 素朴に「識別子 + `(`」で探すと**宣言ごと見えなくなる**。見えない関数は
  /// sink に数えられず、`log<Object>('failed: $e')` が緑のまま通る。
  List<(String, String, int, int)> declarationsOf(String source) {
    final out = <(String, String, int, int)>[];
    for (final m in RegExp(
      r'([A-Za-z_][A-Za-z0-9_]*)\s*[(<]',
    ).allMatches(source)) {
      final name = m.group(1)!;
      if (notDeclarations.contains(name)) continue;
      final open = parenAfter(source, m.end - 1);
      if (open < 0) continue;
      final close = matchParen(source, open);
      if (close < 0) continue;
      // 引数リストの後ろ。`async` / `async*` / `sync*` は読み飛ばす。
      final after = RegExp(
        r'^\s*(?:async\*?|sync\*)?\s*',
      ).firstMatch(source.substring(close + 1))!;
      var i = close + 1 + after.end;
      if (i >= source.length) continue;
      if (source[i] == '{') {
        final end = matchBracket(source, i, '{', '}');
        if (end < 0) continue;
        out.add((name, source.substring(open + 1, close), i, end));
      } else if (source.startsWith('=>', i)) {
        // arrow 本体は文末まで。文字列中の `;` を終端にしないよう順に見る。
        String? quote;
        for (var j = i; j < source.length; j++) {
          final c = source[j];
          if (quote != null) {
            if (c == r'\') {
              j++;
            } else if (c == quote) {
              quote = null;
            }
            continue;
          }
          if (c == "'" || c == '"') {
            quote = c;
            continue;
          }
          if (c == ';') {
            out.add((name, source.substring(open + 1, close), i, j));
            break;
          }
        }
      }
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

  /// `String` の仮引数 1 つぶん。
  final stringParamDecl = RegExp(
    r'^\s*(?:required\s+)?String\??\s+([a-z_][A-Za-z0-9_]*)',
  );

  /// 仮引数リストから `String` の引数名を取り出す。
  ///
  /// ⚠ **名前付き / 省略可能引数を取りこぼさない（#1020・Codex P2）。**
  /// `{required String message}` は [splitArgs] にとって `{}` の中身が
  /// ネストなので**丸ごと 1 個の断片**として返る。区切りを剥がしてから
  /// もう一段割らないと、`^` 固定の照合が外れて `names` が空になり、
  /// **そのラッパーは黙って検査対象から消える**。
  Set<String> stringParamNames(String params) {
    final out = <String>{};
    for (final group in splitArgs(params)) {
      final inner = group
          .replaceFirst(RegExp(r'^[{\[]\s*'), '')
          .replaceFirst(RegExp(r'\s*[}\]]$'), '');
      for (final p in splitArgs(inner)) {
        final m = stringParamDecl.firstMatch(p);
        if (m != null) out.add(m.group(1)!);
      }
    }
    return out;
  }

  /// [expr] が [params] のいずれかを参照しているか。
  ///
  /// 素の `m`・補間の `$m` / `${m}`・三項の `… : m` をまとめて拾う。
  ///
  /// ⚠ **`m.trim()` のような加工も転送とみなす（#1020・Codex P2 の 4 巡目）。**
  /// [params] は **`String` の仮引数だけ**なので、そこから生えるメソッドは
  /// 構造体のフィールド取り出しとは違い、**中身の文字列をそのまま持っている**。
  /// `trim()` しても例外文は消えない。`m.length` のように文字列を持たない結果も
  /// 拾ってしまうが、**緩い側の誤りは害が無い**（その関数の呼び出し側で
  /// 「生の例外を埋めていないか」を見るだけ）。
  ///
  /// ⚠ **前に `.` が付く形は拾わない。**`other.message` は同名の別物。
  bool referencesAny(String expr, Iterable<String> params) => params.any(
    (p) => RegExp('(?<![A-Za-z0-9_.])$p(?![A-Za-z0-9_])').hasMatch(expr),
  );

  /// 名前付き引数の `名前:` 部分。⚠ 三項演算子の `:` を誤認しないよう、
  /// **識別子 + `:` が先頭に来る**ことを見る。
  final namedArgLabel = RegExp(r'^[a-z_][A-Za-z0-9_]*\s*:\s*');

  /// [args]（呼び出しの引数リスト）が [params] のどれかを転送しているか。
  ///
  /// ⚠ **引数リスト全体と引数名を比べない（#1020・Codex P2 の 3 巡目）。**
  /// `debugPrint(message, wrapWidth: 100)` のように**他の引数と並ぶ**と、
  /// 全体の文字列は引数名と一致しないので転送とみなされず、**そのラッパーが
  /// sink から漏れる**。1 つずつ割って見る。
  ///
  /// 名前付き引数は**値の側**を見る（`debugPrint(m, wrapWidth: n)` の `m`、
  /// `log(message: m)` の `m`）。
  bool forwardsTo(String args, Set<String> params) =>
      splitArgs(args).any((arg) {
        final label = namedArgLabel.firstMatch(arg);
        return referencesAny(
          label == null ? arg : arg.substring(label.end),
          params,
        );
      });

  /// [sources] 全体から転送候補（`String` を受け取る関数）を集める。
  List<({String name, Set<String> params, String body})> candidatesIn(
    Iterable<String> sources,
  ) => [
    for (final source in sources)
      for (final (name, params, bodyStart, bodyEnd) in declarationsOf(source))
        if (stringParamNames(params) case final names when names.isNotEmpty)
          (
            name: name,
            params: names,
            body: source.substring(bodyStart, bodyEnd),
          ),
  ];

  /// breadcrumb になりうるログ経路を**ソースから数え上げる**。
  ///
  /// ⚠ **`debugPrint` だけでは足りない。**`main.dart` の `_logDev` のような
  /// 薄いラッパーを経由すると、名前だけ見ている検査はすり抜ける（#975 の
  /// 再発はここから起きた）。
  ///
  /// ⚠⚠ **手で一覧を持つのもだめ（#1020・Codex P2）。**一覧に足し忘れた関数は
  /// 検査から消えるだけで、何も言わずに緑になる。**転送している関数を毎回
  /// ソースから見つけ直す**ので、足し忘れという状態が存在しない。
  ///
  /// ⚠⚠ **ファイルごとに数えてもだめ（#1020・Codex P2 の 2 巡目）。**共有の
  /// `log(String m) => debugPrint(m);` を別ファイルから `log('$e')` と呼ぶと、
  /// 呼び出し側のソースには宣言が無いので `debugPrint` しか sink に見えない。
  /// **全ファイルを見てから**呼び出し側を検査する。
  ///
  /// 転送とみなす形は 2 つ:
  ///
  /// 1. `debugPrint(message)` — 受け取った値をそのまま流す
  /// 2. `debugPrint('prefix: $message')` — **リテラルで始まるのに転送している**。
  ///    第 1 引数がリテラルかどうかだけ見ていると素通りし、後から
  ///    `log('$e')` と書かれても検査は全部緑のままになる
  ///
  /// 検出が緩くて無関係な関数を拾っても害は無い。その関数の呼び出し側でも
  /// 「生の例外を埋めていないか」を見るだけで、それは元々満たすべき条件。
  Set<String> breadcrumbSinks(Iterable<String> sources) {
    final sinks = {'debugPrint'};
    final pending = candidatesIn(sources);
    var added = true;
    // 転送が数珠つなぎになることがある（`_logDevException` → `_logDev` →
    // `debugPrint`）。増えなくなるまで回す。
    while (added) {
      added = false;
      pending.removeWhere((c) {
        final forwards = sinks.any(
          (sink) => callsOf(
            c.body,
            sink,
          ).any((call) => forwardsTo(call.$1, c.params)),
        );
        if (!forwards) return false;
        sinks.add(c.name);
        added = true;
        return true;
      });
    }
    return sinks;
  }

  /// `パス → ソース` から違反を数え上げる。
  ///
  /// ⚠ **合成ソースで丸ごと動かせる形にしておくこと（#1020・Codex P2 の 5 巡目）。**
  /// 部品ごとの検査しか持っていなかったため、「ラッパーは見つかるのに、その
  /// **呼び出し**が見えない」という穴を自分のテストで踏めなかった。
  List<String> offendersIn(Map<String, String> sources) {
    // ⚠ **sink の数え上げは全ファイルを見てから。**呼び出し側のソースだけでは
    // 別ファイルで宣言された転送ラッパーが見えない。
    final sinks = breadcrumbSinks(sources.values);
    final offenders = <String>[];
    for (final MapEntry(key: path, value: source) in sources.entries) {
      if (allowedFiles.contains(path)) continue;
      for (final sink in sinks) {
        for (final (args, start) in callsOf(source, sink)) {
          final unsafe = unsafeInterpolations(args);
          if (unsafe.isEmpty) continue;
          if (isMarked(source, start)) continue;
          offenders.add('$path: $sink → ${unsafe.join(' / ')}');
        }
      }
    }
    return offenders;
  }

  test('ログ経路に捕捉した例外を埋めない（scrub 済みを渡す）', () {
    final offenders = offendersIn({
      for (final f in dartFiles()) relativePath(f): f.readAsStringSync(),
    });
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

  /// ラッパー検出が実際に効くこと。**ここが緩いと、上の検査は debugPrint の
  /// 直呼びしか見なくなる**（#975 の取りこぼしの正体がこれ）。
  test('debugPrint へ値を転送する関数を見つける', () {
    // 1. そのまま流す形。
    const passthrough = 'void logA(String message) { debugPrint(message); }';
    expect(breadcrumbSinks([passthrough]), contains('logA'));

    // 2. リテラルに埋めて流す形。⚠ **第 1 引数がリテラルかどうかだけ見ていると
    //    ここを素通りする**（#1020・Codex P2）。
    const prefixed = "void logB(String m) => debugPrint('prefix: \$m');";
    expect(breadcrumbSinks([prefixed]), contains('logB'));

    // 3. 数珠つなぎ。`logD` → `logC` → debugPrint。
    const chained =
        'void logC(String m) { debugPrint(m); }\n'
        "void logD(String m) { logC('x: \$m'); }";
    expect(breadcrumbSinks([chained]), containsAll(['logC', 'logD']));
  });

  /// ⚠ **名前付き / 省略可能引数（#1020・Codex P2 の 2 巡目）。**
  /// `{required String message}` は `splitArgs` にとって丸ごと 1 断片なので、
  /// 区切りを剥がさないと引数名が取れず、**そのラッパーは黙って検査対象から
  /// 消える**。`log(message: '$e')` が素通りするようになる。
  test('名前付き / 省略可能の String 引数も拾う', () {
    const named =
        "void logE({required String message}) => debugPrint(message);";
    expect(breadcrumbSinks([named]), contains('logE'));

    const optional = "void logF([String? m]) => debugPrint('x: \$m');";
    expect(breadcrumbSinks([optional]), contains('logF'));

    const mixed =
        'void logG(int n, {String? a, required String b}) '
        '=> debugPrint(b);';
    expect(breadcrumbSinks([mixed]), contains('logG'));
  });

  /// ⚠ **他の引数と並ぶ形（#1020・Codex P2 の 3 巡目）。**引数リスト全体と
  /// 引数名を比べていると、`debugPrint(m, wrapWidth: 100)` は一致せず
  /// **そのラッパーが sink から漏れる**。1 つずつ割って見る。
  test('他の引数と並んでいても転送とみなす', () {
    const positional = 'void logH(String m) => debugPrint(m, wrapWidth: 100);';
    expect(breadcrumbSinks([positional]), contains('logH'));

    // 名前付き引数は値の側を見る。
    const named =
        'void logI(String m) => debugPrint(m, wrapWidth: 100);\n'
        'void logJ(String m) { logI(m); }';
    expect(breadcrumbSinks([named]), containsAll(['logI', 'logJ']));

    // ⚠ 三項演算子の `:` を名前付き引数と読み違えない。
    const ternary =
        "void logK(String m) => debugPrint(m.isEmpty ? 'none' : m);";
    expect(breadcrumbSinks([ternary]), contains('logK'));
  });

  /// ⚠⚠ **別ファイルで宣言されたラッパー（#1020・Codex P2 の 2 巡目）。**
  /// ファイルごとに数えると、呼び出し側のソースには宣言が無いので
  /// `debugPrint` しか sink に見えず、`log('$e')` が素通りする。
  test('別ファイルのラッパーも sink として数える', () {
    const declaration = 'void sharedLog(String m) { debugPrint(m); }';
    const callerOnly = "void doIt() { sharedLog('failed: \$e'); }";

    expect(
      breadcrumbSinks([callerOnly]),
      isNot(contains('sharedLog')),
      reason: '呼び出し側のソースだけでは見つけようがない',
    );
    expect(breadcrumbSinks([declaration, callerOnly]), contains('sharedLog'));
  });

  /// ⚠ **総称型の宣言（#1020・Codex P2 の 4 巡目）。**名前と `(` の間に型引数が
  /// 挟まると、素朴な「識別子 + `(`」の照合では**宣言ごと見えなくなる**。
  test('総称型のラッパーも見つける', () {
    const generic = 'void logL<T>(String m) => debugPrint(m);';
    expect(breadcrumbSinks([generic]), contains('logL'));

    const bounded = 'void logM<T extends Object>(String m) { debugPrint(m); }';
    expect(breadcrumbSinks([bounded]), contains('logM'));
  });

  /// ⚠⚠ **見つけただけでは足りない（#1020・Codex P2 の 5 巡目）。**宣言側だけ
  /// `<…>` を読み飛ばすようにすると、`logQ` は sink として**見つかるのに**
  /// `logQ<Object>('failed: $e')` という**呼び出しが見えない**。検査は動いて
  /// いるのに素通りする、いちばんたちの悪い形になる。
  ///
  /// 4 巡目の検査が「検出」しか見ておらず、**呼び出しを一度も通していなかった**
  /// ことが穴を残した。ここは通しで動かす。
  test('総称型の呼び出しも見える（型引数つきの実呼び出し）', () {
    expect(
      offendersIn({
        'a.dart': 'void logQ<T>(String m) => debugPrint(m);',
        'b.dart': "void run() { logQ<Object>('failed: \$e'); }",
      }),
      isNotEmpty,
      reason: '型引数が挟まるだけで見えなくなってはいけない',
    );
  });

  /// 通しで動かす最小の筋書き。**部品ごとの検査だけにしない**ための土台。
  test('別ファイルのラッパー越しの生例外を、通しで捕まえる', () {
    expect(
      offendersIn({
        'a.dart': 'void logR(String m) { debugPrint(m); }',
        'b.dart': "void run() { logR('failed: \$e'); }",
      }),
      isNotEmpty,
    );
    expect(
      offendersIn({
        'a.dart': 'void logS(String m) { debugPrint(m); }',
        'b.dart': "void run() { logS('failed: \${scrubException(e)}'); }",
      }),
      isEmpty,
      reason: 'scrub 済みまで落としては、直しようが無くなる',
    );
  });

  /// ⚠ **`String` 引数への加工は転送（#1020・Codex P2 の 4 巡目）。**
  /// `trim()` しても例外文は消えない。候補は `String` の仮引数だけなので、
  /// そこから生えるメソッドは構造体のフィールド取り出しとは別物。
  test('String 引数を加工して渡す形も転送とみなす', () {
    const trimmed = 'void logN(String m) => debugPrint(m.trim());';
    expect(breadcrumbSinks([trimmed]), contains('logN'));

    const sliced =
        "void logO(String m) => debugPrint('x: \${m.substring(0)}');";
    expect(breadcrumbSinks([sliced]), contains('logO'));
  });

  /// 転送の判定が呼び出し側まで広がらないこと。ここが緩いと、**ただ引数を
  /// ログに書いているだけの関数が全部 sink になって**、検査の意味が薄れる。
  ///
  /// ⚠ **効いているのは「`String` の仮引数だけを候補にする」ほう。**
  /// `.` の有無ではない（`String` 引数の `.trim()` は上のとおり転送とみなす）。
  test('String 以外の引数はそもそも候補にしない', () {
    const callSite =
        'void save(Account account) {\n'
        "  debugPrint('failed for \${account.key.host}');\n"
        '}';
    expect(breadcrumbSinks([callSite]), isNot(contains('save')));
  });

  /// 同名の別物を拾わない。`other.message` は引数 `message` ではない。
  test('前に `.` が付く同名は拾わない', () {
    const other = 'void logP(String message) { debugPrint(config.message); }';
    expect(breadcrumbSinks([other]), isNot(contains('logP')));
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
