import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

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

  /// コメントを**同じ長さの空白**へ潰す。改行は残すので index も行番号もずれない。
  ///
  /// ⚠ **括弧の対応付けはコメントを読んではいけない（#1020・Codex P2 の 6 巡目）。**
  /// 本体に `// payload は {'key': value} の形` のような行があると、[matchBracket]
  /// がその `}` を数えて**本体がそこで終わったことになる**。以降の
  /// `debugPrint(message)` が本体の外に出るので、そのラッパーは sink から漏れ、
  /// `log('failed: $e')` が緑のまま通る。
  ///
  /// 潰しておくと**コメントアウトされたコードを違反として数えない**副次効果もある
  /// （`// debugPrint('$e')` は実行されないので、直せと言われても困る）。
  ///
  /// ⚠ **実体は `test/support/dart_source.dart` へ移した (#1035-C5)。**素朴な
  /// 行コメント落としが 3 本のガードへ写されていて、そのうち 1 本に実害
  /// （URL リテラルを含む行が丸ごと消える）が出たため、リテラルを見るこの版へ
  /// 統一した。

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
  /// 例外を受けている変数名か (#1035-C2)。
  ///
  /// ⚠⚠ **列挙ではなく接尾辞で見る。**`(e|err|error|ex|exception)` の列挙だと
  /// `catch (clearErr)`（`login_screen.dart`）と `catch (deleteErr)`
  /// （`fcm_service.dart`）が外れる。どれも現状は `runtimeType.toString()` か
  /// [debugLogException] への転送で安全だが、**この 3 箇所に
  /// `debugPrint('boom: $clearErr')` を書き足しても緑**だった。
  /// 525120a2 で storage key の列挙を接尾辞判定へ直したのと同じ形に揃える。
  ///
  /// ⚠ **「末尾が e」で拾わない。**`$value` / `$name` / `$type` が全部当たる。
  /// 複合語は**大文字境界**（`clearErr` の `E`）を要求する。
  const exactErrorNames = {'e', 'err', 'error', 'ex', 'exception'};
  final errorSuffix = RegExp(r'[a-z0-9](?:Err|Error|Ex|Exception)$');
  bool isErrorIdentifier(String name) =>
      exactErrorNames.contains(name) || errorSuffix.hasMatch(name);

  /// ⚠ **識別子は総取りして [isErrorIdentifier] で絞る。**正規表現に名前を
  /// 焼き込むと、増えた名前が黙って通る（#1035-C2 がまさにそれ）。
  final interpolationStart = RegExp(
    r'\$\{?([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])',
  );

  /// ⚠ **`response` / `details` / `osError` を落とさない (#1027-A4)。**
  ///
  /// - `${e.response}` は `Response.toString()` が**ボディ全体**を返す
  /// - `${e.details}` は `PlatformException` / `IAPError` のネイティブ内部情報
  /// - `${e.osError}` は `SocketException` の OS エラーで、ホスト名と
  ///   ポートを含む
  ///
  /// ⚠ **`statusCode` は通る**（`response` の後ろに続いても、鎖全体に
  /// `response` が現れるので弾かれる点は承知のうえ）。素性だけ欲しいときは
  /// `e.response?.statusCode` ではなく [scrubException] を通すこと。
  final unsafeMembers = RegExp(
    r'\b(message|data|body|uri|path|toString|requestOptions'
    r'|response|details|osError)\b',
  );

  /// 補間ではなく**引数として直に**渡す形（`Breadcrumb(message: e.toString())`）。
  ///
  /// ⚠ **`$` 補間だけを見ていると素通りする（v1.60 リリース前レビュー）。**
  /// `chat_provider` が捕まったのは三項演算子の中にたまたま `${...}` が
  /// あったからで、`message: e.toString()` と素直に書かれていたら
  /// [interpolationStart] は一度も当たらなかった。
  ///
  /// 丸ごとの `e` は**採らない**。`debugLogException(context, e)` のように
  /// scrub を行う側へ渡す正しい形と区別できないため。危ないと言い切れるのは
  /// [unsafeMembers] を引くメンバーアクセスだけ。
  ///
  /// ⚠ **ここも [isErrorIdentifier] で絞る (#1035-C2)。**列挙のままだと
  /// `clearErr.message` のような形が外れる。
  final bareMemberAccess = RegExp(
    r'(?<![A-Za-z0-9_.$])([A-Za-z_][A-Za-z0-9_]*)\.',
  );

  /// メンバーアクセスの連なりが危ないか。
  ///
  /// ⚠ **`runtimeType` を通った先は型名しか出ない。**`e.runtimeType.toString()`
  /// は breadcrumb に載せる**正しい**形なので、`toString` に反応して弾いては
  /// いけない（この除外が無いと timeline_provider / chat_provider /
  /// desktop_notification_dispatcher の正しい実装が軒並み違反になる）。
  /// 素性しか出さないと分かっている鎖。**通した理由を必ず書くこと。**
  ///
  /// ⚠ **`response` を丸ごと安全扱いにしない (#1027-A4)。**危ないのは
  /// `Response.toString()`（ボディ全体）であって、そこから 1 つ引いた
  /// `statusCode` は数値。**鎖の終端まで見て、この形ちょうどのときだけ**通す。
  final safeChains = <RegExp>[
    // dio の HTTP ステータス。数値しか出ない。
    RegExp(r'^response\??\.statusCode$'),
  ];

  bool unsafeChain(String chain) {
    // 型名しか出ない。`e.runtimeType.toString()` は breadcrumb に載せる正しい形。
    if (chain.startsWith('runtimeType')) return false;
    if (safeChains.any((r) => r.hasMatch(chain))) return false;
    return unsafeMembers.hasMatch(chain);
  }

  /// [args] の中の危ない補間を返す。
  List<String> unsafeInterpolations(String args) {
    final found = <String>[];
    final chainAfter = RegExp(r'^[A-Za-z0-9_.?\[\]]*');
    for (final m in interpolationStart.allMatches(args)) {
      if (!isErrorIdentifier(m.group(1)!)) continue;
      final after = args.substring(m.end);
      // ⚠ **呼び出しは変数ではない (#1035-C2)。**接尾辞判定にしたことで
      // `scrubException(...)` / `summarizeOpError(...)` のような**関数名**まで
      // 当たるようになった。`${scrubException(e)}` は scrub を通す**正しい**形
      // なので、直後が `(` なら変数ではないと見て飛ばす。
      if (after.startsWith('(')) continue;
      if (!after.startsWith('.') && !after.startsWith('?.')) {
        // `$e` / `${e}` — オブジェクトを丸ごと埋めている。
        found.add(m.group(0)!);
        continue;
      }
      // メンバーアクセス。補間の終端（`}` か、識別子・`.`・`?` の切れ目）まで見る。
      final chain = chainAfter.firstMatch(after)!.group(0)!;
      if (unsafeChain(chain.replaceFirst(RegExp(r'^\??\.'), ''))) {
        found.add('${m.group(0)}$chain');
      }
    }
    for (final m in bareMemberAccess.allMatches(args)) {
      if (!isErrorIdentifier(m.group(1)!)) continue;
      final chain = chainAfter.firstMatch(args.substring(m.end))!.group(0)!;
      if (unsafeChain(chain)) found.add('${m.group(0)}$chain');
    }
    return found;
  }

  String relativePath(File f) =>
      f.path.replaceFirst('${Directory.current.path}/', '');

  /// ログ経路に載せてはいけないアカウント識別子 (#1027-A3 / B)。
  ///
  /// ⚠⚠ **この検査は例外しか見ていなかった。**動機に挙げているのは
  /// 「breadcrumb の message は `_scrubBreadcrumb` を通らない」ことなのに、
  /// [interpolationStart] は `e` / `error` 系の識別子しか対象にしていない。
  /// **`'... for $accountKey'` は例外ですらないので一度も引っかからなかった**。
  /// #1020 で `account_storage.dart` の 1 行を直したときも、同じファイルの
  /// 隣の行や `push_message_dispatcher.dart:174` は残っていた。
  ///
  /// 載っていた実体は `mastodon://user@host`（storage key）や
  /// `username@host`。**host は残してよい**（プリセットかどうかで優先度を
  /// 切る運用があり、素性が分からないとトリアージできない）ので、
  /// 潰すのは username 側だけ。`sentrySafeAccount` を通すこと。
  final accountIdentifiers = <({RegExp pattern, String what})>[
    (
      pattern: RegExp(r'\.toStorageKey\(\)'),
      what: 'toStorageKey() （mastodon://user@host そのもの）',
    ),
    (
      // `$accountKey` / `${accountKey}` / `$keyStr` / `${storageKey}`
      //
      // ⚠ **変数名を列挙しない。**以前は `(accountKey|keyStr|storageKey)` の
      // 完全一致だったため、`$accountStorageKey` がどれにも当たらず素通しに
      // なっていた（`announcement_subscription_service.dart` の 2 箇所が実際に
      // 漏れており、v1.61 のリリース前レビューで検出）。**列挙は必ず取りこぼす**
      // ので、接尾辞で見て前置きは何でも許す形にする。
      // ⚠ **`sentrySafe…` 自身を拾わないこと。**`${sentrySafeAccountKey(k)}`
      // は接尾辞 `AccountKey` に当たってしまう＝**正しい直し方をした箇所だけが
      // 違反として出る**ので、先頭で除外する。
      pattern: RegExp(
        r'\$\{?(?!sentrySafe)[A-Za-z0-9_]*'
        r'(?:[Ss]torageKey|[Aa]ccountKey|keyStr)(?![A-Za-z0-9_])',
      ),
      what: 'storage key の補間',
    ),
    (
      // ⚠ **`$account` を丸ごと埋める形 (#1027-B)。**この名前の変数は
      // `Account` か storage key 文字列で、後者だと `mastodon://user@host`
      // がそのまま出る。`push_message_dispatcher.dart:174` が実際にこれで、
      // **同じファイルの 14 行下は #1020 で直っていたのに残っていた**。
      //
      // ⚠ **`.` が続く形は除く。**`${account.key.host}` は host だけなので可。
      // 危ないのは「丸ごと」だけ。
      pattern: RegExp(r'\$\{?account(?![A-Za-z0-9_.])'),
      what: 'account を丸ごと補間',
    ),
    (
      // `${account.key.username}` / `${a.key.username}` / `$username`
      pattern: RegExp(r'\$\{?[A-Za-z0-9_.?]*\busername\b'),
      what: 'username の補間',
    ),
  ];

  /// [args] に含まれるアカウント識別子を返す。
  List<String> accountLeaks(String args) => [
    for (final id in accountIdentifiers)
      if (id.pattern.hasMatch(args)) id.what,
  ];

  /// `captureMessage` の `params:` に載せてよい形 (#1027-A5)。
  ///
  /// ⚠⚠ **`params` は `logentry.params` として実際に送信される。**`hint` が
  /// `beforeSend` へ渡るだけで送られないのとは違う。にもかかわらず、この検査は
  /// `captureMessage` を一度も見ていなかった。`conversion_skip_report` /
  /// `timeline_provider` が `[item.id, item.error]` を渡しており、`item.error` は
  /// adapter が作る `'$e'`（＝ FormatException の source ＝**投稿本文**）だった。
  ///
  /// 通すのは **ID とリテラルだけ**。denylist ではなく allowlist にするのは、
  /// 「危ない名前」を数え上げる形だと**次に増えた名前が黙って通る**ため。
  /// 素性を丸めた値を載せたいときは [marker] で個別に抜ける（理由が残る）。
  final safeParamEntry = RegExp(
    // 文字列 / 数値リテラル
    r'''^(?:'[^']*'|"[^"]*"|[0-9]+)$'''
    // `item.id` / `postId` / `x?.id` のような ID
    r'''|^[A-Za-z_][A-Za-z0-9_]*(?:\??\.[A-Za-z_][A-Za-z0-9_]*)*'''
    r'''(?<=[Ii]d|ID)$''',
  );

  test('captureMessage の params に ID とリテラル以外を載せない (#1027-A5)', () {
    final offenders = <String>[];
    for (final file in dartFiles()) {
      final path = relativePath(file);
      if (allowedFiles.contains(path)) continue;
      final original = file.readAsStringSync();
      final source = maskComments(original);
      for (final (args, start) in callsOf(source, 'captureMessage')) {
        if (isMarked(original, start)) continue;
        for (final arg in splitArgs(args)) {
          if (!arg.startsWith('params:')) continue;
          final list = arg.substring('params:'.length).trim();
          final inner = list
              .replaceFirst(RegExp(r'^\[\s*'), '')
              .replaceFirst(RegExp(r'\s*\]$'), '');
          for (final entry in splitArgs(inner)) {
            if (entry.isEmpty) continue;
            if (safeParamEntry.hasMatch(entry)) continue;
            offenders.add('$path: captureMessage(params: [… $entry …])');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'params は logentry.params として実際に送信される（hint と違う）。'
          'ID とリテラル以外を載せないこと。素性へ丸めた値なら '
          '`// $marker: <理由>` で個別に抜ける\n${offenders.join('\n')}',
    );
  });

  /// ⚠ **検査そのものが効いていることを、合成ソースで確かめる。**
  /// 上の検査はリポジトリが綺麗になった時点で「常に緑」になるので、
  /// **判定ロジックが壊れても気づけない**。
  group('params の判定 (#1027-A5)', () {
    bool safe(String entry) => safeParamEntry.hasMatch(entry);

    test('ID とリテラルは通す', () {
      expect(safe('post.id'), isTrue);
      expect(safe('item?.id'), isTrue);
      expect(safe('notificationId'), isTrue);
      expect(safe('maxId'), isTrue);
      expect(safe("'fixed'"), isTrue);
      expect(safe('42'), isTrue);
    });

    test('それ以外は弾く', () {
      expect(safe('post.error'), isFalse);
      expect(safe('e.toString()'), isFalse);
      expect(safe('body'), isFalse);
      // ⚠ **`id` を含むだけでは通さない。**終端が id であること。
      expect(safe('post.identity'), isFalse);
      expect(safe('idle'), isFalse);
    });
  });

  /// ⚠ **`response` を丸ごと安全扱いにしていないこと (#1027-A4)。**
  test('response の鎖は終端まで見る', () {
    expect(unsafeChain('response?.statusCode'), isFalse, reason: '数値だけ');
    expect(unsafeChain('response.statusCode'), isFalse);
    expect(unsafeChain('response'), isTrue, reason: 'toString はボディ全体');
    expect(unsafeChain('response?.data'), isTrue);
    expect(unsafeChain('details'), isTrue, reason: 'ネイティブの内部情報');
    expect(unsafeChain('osError'), isTrue, reason: 'ホスト名とポート');
    expect(unsafeChain('runtimeType.toString()'), isFalse);
  });

  test('captureException には scrub 済みの例外だけを渡す', () {
    final offenders = <String>[];
    for (final file in dartFiles()) {
      final path = relativePath(file);
      if (allowedFiles.contains(path)) continue;
      final original = file.readAsStringSync();
      // コメント内の括弧を数えないよう潰してから見る（長さは変わらない）。
      final source = maskComments(original);
      for (final (args, start) in callsOf(source, 'captureException')) {
        final first = splitArgs(args).firstOrNull;
        if (first == null || first.isEmpty) continue;
        if (isMarked(original, start)) continue;
        // scrub 済み / その場で作った合成エラー（`StateError('...')` 等）は可。
        if (first.startsWith('scrubException(')) continue;
        // 直前で `final scrubbed = scrubException(e);` と控えた変数も可。
        // ⚠ **名前だけで信じる**ので、`scrubbed` を別の意味に使わないこと。
        if (RegExp(r'^scrubbed[A-Za-z0-9_]*$').hasMatch(first)) continue;
        // その場で作った合成エラー（`StateError('...')` 等）。
        //
        // ⚠⚠ **無条件に通してはいけない (#1027-A2)。**免除していたのは
        // 「型名 + `(`」の形だけで、**中身を一度も見ていなかった**。
        // `StateError('$accountKey が読めません: $e')` のように**中に PII や
        // 生の例外を組み込んだ合成エラー**は、素の `e` を渡すより悪い
        // （`exceptions[].value` は breadcrumb と違って必ず送られる）。
        if (RegExp(r'^[A-Z][A-Za-z0-9_]*\(').hasMatch(first)) {
          final open = first.indexOf('(');
          final close = matchParen(first, open);
          final inner = close < 0 ? first : first.substring(open + 1, close);
          final leaks = [
            ...unsafeInterpolations(inner),
            ...accountLeaks(inner),
          ];
          if (leaks.isEmpty) continue;
          offenders.add(
            '$path: captureException($first) → ${leaks.join(' / ')}',
          );
          continue;
        }
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
  ///
  /// ⚠ **注釈を読み飛ばす。**`@Tag() String message` のように仮引数へ
  /// メタデータが付くと、`^` 固定の照合は `@` を見て外れ、**そのラッパーが
  /// 黙って検査対象から消える**。
  final stringParamDecl = RegExp(
    r'^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^()]*\))?\s*)*'
    r'(?:required\s+)?String\??\s+([a-z_][A-Za-z0-9_]*)',
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
  ///
  /// ⚠⚠ **根は `debugPrint` だけではない（v1.60 リリース前レビュー）。**この検査
  /// が動機に挙げているのは「breadcrumb の message は `_scrubBreadcrumb` を
  /// 通らない」ことなのに、根が `debugPrint` 固定だったため **`Breadcrumb` を
  /// 直接組み立てる経路を一度も見ていなかった**。`chat_provider` の
  /// `onParseError` が `jsonDecode` の FormatException を `message:` に素で
  /// 載せており（＝チャット本文が Sentry へ）、検査は緑のままだった。
  /// breadcrumb を作る本人を根に入れる。
  Set<String> breadcrumbSinks(Iterable<String> sources) {
    final sinks = {'debugPrint', 'Breadcrumb'};
    final pending = candidatesIn(sources.map(maskComments));
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
  /// ログ用のラッパーらしい名前か (#1027-A3)。
  ///
  /// ⚠⚠ **アカウント識別子の検査では [breadcrumbSinks] をそのまま使えない。**
  /// あちらは「String を受け取って debugPrint へ転送する関数」を**緩めに**
  /// 拾う。例外の検査ではそれで害が無い（生の例外を受け取る関数はどこであれ
  /// 怪しい）が、こちらでは違う — **storage key を storage API へ渡すのは
  /// 正しい用途**なのに、`saveAccount` / `removeAccount` /
  /// `PushRelayClient.register` が「sink」に数えられて全部違反になる。
  /// 実際 24 件のうち 6 件がこの形だった。
  ///
  /// そこで名前でふるいにかける。⚠ **手で一覧を持つのとは違う** — 一覧なら
  /// 足し忘れた関数が黙って検査から消えるが、ここは fixpoint で見つけた集合を
  /// 絞るだけなので、**新しいログラッパーも名前が合えば自動で入る**。
  ///
  /// ⚠ 名前が合わないログラッパー（`note()` 等）は漏れる。下の
  /// 「既知のラッパーを取りこぼしていない」でそこを押さえる。
  final logLikeName = RegExp(
    r'log|print|trace|breadcrumb|report|debug',
    caseSensitive: false,
  );

  Set<String> accountSinks(Iterable<String> masked) => breadcrumbSinks(
    masked,
  ).where((s) => s == 'Breadcrumb' || logLikeName.hasMatch(s)).toSet();

  /// `Sentry.captureException` へ**到達する**関数を数え上げる (#1027-A1)。
  ///
  /// ⚠⚠ **例外側は直接呼び出ししか見ていなかった。**breadcrumb 側は fixpoint で
  /// ラッパーを辿るのに、こちらは `captureException(` の呼び出しだけを見ていた
  /// ので、`reportOpFailure` / `_reportOnce` を経由すると**検査の視野から
  /// 消えていた**。
  ///
  /// これが効くのは、ラッパーが内部で `scrubException` を通していても
  /// **他の引数が素通しになる**ため。`reportOpFailure` の `tags` は
  /// `Map<String, String>` がそのまま Sentry のタグになるので、
  /// `tags: {'detail': '$e'}` と書けば生の例外が送られる。
  ///
  /// ⚠⚠ **「本体が sink を呼んでいる」だけで sink と見なしてはいけない。**
  /// [callsOf] / [declarationsOf] は**名前でしか照合しない**ので、`update` の
  /// ような一般的なメソッド名が 1 つ混ざると fixpoint が爆発する。実際、
  /// 無関係な `PushRegistrationStatusStore.update`（UI 状態の保管庫）まで
  /// sink になり、`errorMessage: e.message` が違反として挙がった。
  ///
  /// breadcrumb 側と同じく**自分の引数を転送していること**を要求する。例外は
  /// `Object` / `dynamic` / `〜Exception` / `〜Error` 型で受けるので、String
  /// 前提の [stringParamNames] とは別に集める。
  final errorParamDecl = RegExp(
    r'^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^()]*\))?\s*)*'
    r'(?:required\s+)?'
    r'(?:Object|dynamic|[A-Za-z0-9_]*(?:Exception|Error))\??\s+'
    r'([a-z_][A-Za-z0-9_]*)',
  );

  Set<String> errorParamNames(String params) {
    final out = <String>{};
    for (final group in splitArgs(params)) {
      final inner = group
          .replaceFirst(RegExp(r'^[{\[]\s*'), '')
          .replaceFirst(RegExp(r'\s*[}\]]$'), '');
      for (final p in splitArgs(inner)) {
        final m = errorParamDecl.firstMatch(p);
        if (m != null) out.add(m.group(1)!);
      }
    }
    return out;
  }

  Set<String> exceptionSinks(Iterable<String> masked) {
    final sinks = {'captureException'};
    final pending = [
      for (final source in masked)
        for (final (name, params, bodyStart, bodyEnd) in declarationsOf(source))
          if (errorParamNames(params) case final names when names.isNotEmpty)
            (
              name: name,
              params: names,
              body: source.substring(bodyStart, bodyEnd),
            ),
    ];
    var added = true;
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

  /// ⚠ **合成エラーの免除は無条件ではない (#1027-A2)。**免除していたのは
  /// 「型名 + `(`」の形だけで、中身を一度も見ていなかった。ここが緩いと、
  /// **素の `e` を渡すより悪い**形（PII を組み込んだ合成エラー）が通る。
  group('合成エラーの中身 (#1027-A2)', () {
    /// [captureException] の第 1 引数だけを与えて、違反になるか見る。
    bool rejects(String first) {
      if (!RegExp(r'^[A-Z][A-Za-z0-9_]*\(').hasMatch(first)) return true;
      final open = first.indexOf('(');
      final close = matchParen(first, open);
      final inner = close < 0 ? first : first.substring(open + 1, close);
      return unsafeInterpolations(inner).isNotEmpty ||
          accountLeaks(inner).isNotEmpty;
    }

    test('素性だけの合成エラーは通す', () {
      expect(rejects("StateError('prefs.setString returned false')"), isFalse);
      expect(
        rejects("StateError('DioException type=\$type status=\$code')"),
        isFalse,
      );
    });

    test('中に生の例外を組み込んだ合成エラーは弾く', () {
      expect(rejects("StateError('failed: \$e')"), isTrue);
      expect(rejects("StateError('failed: \${e.message}')"), isTrue);
    });

    test('中にアカウント識別子を組み込んだ合成エラーは弾く', () {
      expect(rejects("StateError('\$accountKey が読めません')"), isTrue);
      expect(rejects("StateError('for \${account.key.username}')"), isTrue);
    });

    test('host だけなら通す', () {
      expect(rejects("StateError('failed for \${account.key.host}')"), isFalse);
    });
  });

  /// `パス → ソース` から、例外ラッパー呼び出しの違反を数え上げる。
  ///
  /// ⚠ `captureException` 自身の第 1 引数は専用の検査が見るので、ここでは
  /// **ラッパー側だけ**を対象にする。
  List<String> offendersInExceptionSinks(Map<String, String> sources) {
    final masked = {
      for (final MapEntry(key: p, value: s) in sources.entries)
        p: maskComments(s),
    };
    final sinks = exceptionSinks(masked.values)..remove('captureException');
    final offenders = <String>[];
    for (final MapEntry(key: path, value: source) in masked.entries) {
      if (allowedFiles.contains(path)) continue;
      for (final sink in sinks) {
        for (final (args, start) in callsOf(source, sink)) {
          final unsafe = unsafeInterpolations(args);
          if (unsafe.isEmpty) continue;
          if (isMarked(sources[path]!, start)) continue;
          offenders.add('$path: $sink → ${unsafe.join(' / ')}');
        }
      }
    }
    return offenders;
  }

  /// ⚠ **この検査はリポジトリが綺麗だと常に緑になる。**判定が壊れても
  /// 気づけないので、合成ソースと実リポジトリの両方で「見えていること」を
  /// 固定する。
  group('例外ラッパーの数え上げ (#1027-A1)', () {
    test('#1027 が名指ししたラッパーが sink に入っている', () {
      final sinks = exceptionSinks([
        for (final f in dartFiles()) maskComments(f.readAsStringSync()),
      ]);
      expect(
        sinks,
        containsAll(['captureException', 'reportOpFailure', '_reportOnce']),
        reason: 'ここが空だと「直接呼び出ししか見ない」に退行する',
      );
    });

    test('ラッパーの他の引数に生の例外を埋めると挙がる', () {
      expect(
        offendersInExceptionSinks({
          'a.dart':
              'void reportX({required Object error, Map<String, String>? tags}) '
              '{ captureException(scrubException(error), tags: tags); }',
          'b.dart':
              "void run() { reportX(error: e, tags: {'detail': '\$e'}); }",
        }),
        isNotEmpty,
        reason: '中で scrubException を通していても、tags は素通しで送られる',
      );
    });

    // ⚠⚠ **名前だけで数えると fixpoint が爆発する。**`update` のような一般的な
    // メソッド名が 1 つ混ざると、無関係な UI 状態の保管庫まで sink になり
    // `errorMessage: e.message` が違反として挙がった（実際に踏んだ）。
    test('引数を転送しない同名メソッドを巻き込まない', () {
      final sinks = exceptionSinks([
        'void report(Object error) { captureException(error); }',
        'void update(String key, {String? errorMessage}) { store[key] = errorMessage; }',
      ]);
      expect(sinks, contains('report'));
      expect(
        sinks,
        isNot(contains('update')),
        reason: 'エラーを受け取らず転送もしないメソッドは sink ではない',
      );
    });
  });

  /// `captureMessage` の**第 1 引数（message 本体）**の違反を数え上げる。
  ///
  /// ⚠⚠ **`params` だけを見ていた (#1035-C1)。**`logentry.message` は `params` と
  /// 同じく**必ず送られる**のに対象外で、`Sentry.captureMessage('failed: $e')` は
  /// 緑のまま通っていた。`params` を allowlist で守った動機がそのまま message にも
  /// 当たる。
  ///
  /// ⚠ **message には allowlist を当てない。**あちらは「ID とリテラルだけ」で
  /// 済む構造化データだが、message は説明文なので素性の補間（`${e.code}` /
  /// `${e.port}`）が正当に入る。**危ない形だけを弾く**（例外の中身 /
  /// アカウント識別子）——本体の掃き出しと同じ判定を当てる。
  List<String> captureMessageOffendersIn(Map<String, String> sources) {
    final offenders = <String>[];
    for (final MapEntry(key: path, value: original) in sources.entries) {
      if (allowedFiles.contains(path)) continue;
      final source = maskComments(original);
      for (final (args, start) in callsOf(source, 'captureMessage')) {
        if (isMarked(original, start)) continue;
        final parts = splitArgs(args);
        if (parts.isEmpty) continue;
        final message = parts.first;
        // 第 1 引数が名前付きなら位置引数の message は無い。
        if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*\s*:').hasMatch(message)) continue;
        final bad = [
          ...unsafeInterpolations(message),
          ...accountLeaks(message),
        ];
        if (bad.isEmpty) continue;
        offenders.add('$path: captureMessage(… ${bad.join(' / ')} …)');
      }
    }
    return offenders;
  }

  test('captureMessage の message に生の例外・識別子を埋めない (#1035-C1)', () {
    final offenders = captureMessageOffendersIn({
      for (final f in dartFiles()) relativePath(f): f.readAsStringSync(),
    });
    expect(
      offenders,
      isEmpty,
      reason:
          'logentry.message は params と同じく必ず送信される。'
          '例外の中身やアカウント識別子は載せず、素性へ丸めること'
          '\n${offenders.join('\n')}',
    );
  });

  /// ⚠ **リポジトリが綺麗だと常に緑になる検査なので、歯を別途固定する。**
  group('message の判定 (#1035-C1)', () {
    test('素性だけの補間は通す', () {
      expect(
        captureMessageOffendersIn({
          'a.dart': r"Sentry.captureMessage('conversion skipped: ${e.code}');",
        }),
        isEmpty,
      );
    });

    test('例外を丸ごと埋めると挙がる', () {
      expect(
        captureMessageOffendersIn({
          'a.dart': r"Sentry.captureMessage('conversion failed: $e');",
        }),
        isNotEmpty,
      );
    });

    test('上流の生データを引く鎖は挙がる', () {
      expect(
        captureMessageOffendersIn({
          'a.dart': r"Sentry.captureMessage('failed: ${e.message}');",
        }),
        isNotEmpty,
      );
    });

    test('アカウント識別子は挙がる', () {
      expect(
        captureMessageOffendersIn({
          'a.dart': r"Sentry.captureMessage('failed for $accountKey');",
        }),
        isNotEmpty,
      );
    });

    test('名前付き引数しか無い呼び出しは message を見ない', () {
      expect(
        captureMessageOffendersIn({
          'a.dart': r"Sentry.captureMessage(template: t, params: [id]);",
        }),
        isEmpty,
      );
    });
  });

  /// ⚠ **列挙をやめた判定に歯があること (#1035-C2)。**
  group('捕捉変数名の判定 (#1035-C2)', () {
    bool flags(String args) => unsafeInterpolations(args).isNotEmpty;

    test('列挙に入っていた名前は従来どおり拾う', () {
      expect(flags(r"'boom: $e'"), isTrue);
      expect(flags(r"'boom: ${error.message}'"), isTrue);
    });

    test('実在した clearErr / deleteErr を拾う', () {
      // ⚠ この 2 つが #1035-C2 の実例。列挙のままだと緑だった。
      expect(flags(r"'boom: $clearErr'"), isTrue);
      expect(flags(r"'boom: ${deleteErr.message}'"), isTrue);
    });

    test('末尾が e というだけの変数は拾わない', () {
      expect(flags(r"'value: $value'"), isFalse);
      expect(flags(r"'name: $name'"), isFalse);
      expect(flags(r"'type: ${type.name}'"), isFalse);
    });

    test('関数呼び出しは変数扱いしない', () {
      // `${scrubException(e)}` は scrub を通す正しい形。
      expect(flags(r"'boom: ${scrubException(e)}'"), isFalse);
    });
  });

  test('captureException へ届く経路に生の例外を埋めない (#1027-A1)', () {
    final offenders = offendersInExceptionSinks({
      for (final f in dartFiles()) relativePath(f): f.readAsStringSync(),
    });
    expect(
      offenders,
      isEmpty,
      reason:
          'ラッパーが中で scrubException を通していても、tags / extra など'
          '**他の引数は素通し**で Sentry へ送られる。生の例外は渡さないこと'
          '\n${offenders.join('\n')}',
    );
  });

  /// アカウント識別子の違反を数え上げる。
  List<String> accountOffendersIn(Map<String, String> sources) {
    final masked = {
      for (final MapEntry(key: p, value: s) in sources.entries)
        p: maskComments(s),
    };
    final sinks = accountSinks(masked.values);
    final offenders = <String>[];
    for (final MapEntry(key: path, value: source) in masked.entries) {
      if (allowedFiles.contains(path)) continue;
      for (final sink in sinks) {
        for (final (args, start) in callsOf(source, sink)) {
          final leaks = accountLeaks(args);
          if (leaks.isEmpty) continue;
          if (isMarked(sources[path]!, start)) continue;
          offenders.add('$path: $sink → ${leaks.join(' / ')}');
        }
      }
    }
    return offenders;
  }

  test('ログ経路にアカウント識別子を埋めない (#1027-A3)', () {
    final offenders = accountOffendersIn({
      for (final f in dartFiles()) relativePath(f): f.readAsStringSync(),
    });
    expect(
      offenders,
      isEmpty,
      reason:
          'breadcrumb の message は _scrubBreadcrumb（data しか見ない）を'
          '通らないので、書いた文字列がそのまま Sentry に出る。'
          'sentrySafeAccount / sentrySafeAccountKey を通すこと'
          '（host は残る・username だけ潰れる）\n${offenders.join('\n')}',
    );
  });

  /// ⚠ **判定そのものが効いていることを合成ソースで確かめる。**
  group('アカウント識別子の判定 (#1027-A3)', () {
    test('storage key / username を拾う', () {
      expect(accountLeaks(r"'no keys for $accountKey'"), isNotEmpty);
      expect(accountLeaks(r"'failed for $keyStr'"), isNotEmpty);
      expect(accountLeaks(r"'x ${account.key.toStorageKey()}'"), isNotEmpty);
      expect(
        accountLeaks(r"'x ${account.key.username}@${a.key.host}'"),
        isNotEmpty,
      );
    });

    /// ⚠ **#1027-B が名指ししていた形。**変数名が `accountKey` ではなく
    /// `account` なので、storage key のパターンだけでは拾えなかった。
    /// 実際この 1 行は #1020 で隣（14 行下）を直したときに残っている。
    test('account を丸ごと埋める形も拾う', () {
      expect(accountLeaks(r"'no push keys for $account'"), isNotEmpty);
      expect(accountLeaks(r"'x ${account}'"), isNotEmpty);
    });

    /// ⚠ **変数名の列挙が取りこぼしていた形（v1.61 のリリース前レビューで検出）。**
    /// 旧パターンは `(accountKey|keyStr|storageKey)` の完全一致だったため、
    /// `$accountStorageKey` がどれにも当たらなかった。
    /// `announcement_subscription_service.dart` の `disable()`（debugPrint）と
    /// `enable()`（StateError のメッセージ）が実際にこれで漏れていた。
    test('接頭辞つきの storage key も拾う', () {
      expect(accountLeaks(r"'disabled $accountStorageKey'"), isNotEmpty);
      expect(accountLeaks(r"'x ${accountStorageKey}'"), isNotEmpty);
      expect(accountLeaks(r"'no endpoint for $currentAccountKey'"), isNotEmpty);
    });

    /// ⚠ **正しい直し方をした箇所を違反にしない。**接尾辞で見るようにした結果、
    /// `${sentrySafeAccountKey(k)}` が `AccountKey` に当たってしまう形が出た。
    /// ここが緑でないと「直すほど赤くなる」検査になる。
    test('sentrySafe 系を通したものは違反にしない', () {
      expect(
        accountLeaks(r"'disabled ${sentrySafeAccountKey(accountStorageKey)}'"),
        isEmpty,
      );
      expect(accountLeaks(r"'x ${sentrySafeAccount(account.key)}'"), isEmpty);
    });

    test('host だけなら通す', () {
      expect(accountLeaks(r"'failed for ${account.key.host}'"), isEmpty);
      expect(accountLeaks(r"'host=$host'"), isEmpty);
    });

    // ⚠ **ラッパー越しでも見える**こと。debugPrint の直呼びしか見ないと、
    // `debugLogException('... $accountKey', e)` が素通りする。
    test('ラッパー越しの呼び出しも捕まえる', () {
      expect(
        accountOffendersIn({
          'a.dart': 'void logX(String m) => debugPrint(m);',
          'b.dart': "void run() { logX('for \$accountKey'); }",
        }),
        isNotEmpty,
      );
    });

    // ⚠⚠ **storage / relay API を違反にしない。**storage key をそれらへ渡すのは
    // 正しい用途で、ログではない。名前で絞る前は 24 件中 6 件がこの形だった。
    test('ログでない関数へ渡すのは違反にしない', () {
      final offenders = accountOffendersIn({
        'a.dart':
            'void saveAccount(String accountKey) '
            "{ debugPrint('saved \$accountKey'); }",
        'b.dart': 'void run() { saveAccount(key.toStorageKey()); }',
      });

      // 呼び出し側は保存 API へ渡しているだけ。挙がってはいけない。
      expect(
        offenders.where((o) => o.startsWith('b.dart')),
        isEmpty,
        reason: 'saveAccount は保存 API であってログではない',
      );
      // ⚠ **中の debugPrint は本物の違反**なので、そちらは挙がること。
      // ここを緩めると「絞りすぎて何も見なくなった」に気づけない。
      expect(
        offenders.where((o) => o.startsWith('a.dart')),
        isNotEmpty,
        reason: '保存 API の中で素の accountKey を出しているのは違反',
      );
    });

    /// ⚠ **名前で絞る以上、既知のラッパーを取りこぼしていないことを確かめる。**
    /// ここが空になると、検査は「debugPrint の直呼びしか見ない」に退行する。
    test('既知のログラッパーは sink に残る', () {
      final sinks = accountSinks([
        for (final f in dartFiles()) maskComments(f.readAsStringSync()),
      ]);
      expect(
        sinks,
        containsAll([
          'debugPrint',
          'Breadcrumb',
          'debugLogException',
          '_trace',
        ]),
      );
    });
  });

  List<String> offendersIn(Map<String, String> sources) {
    // ⚠ **コメントを潰してから構文を見る。**潰さないと本体の終わりを取り違える。
    // 長さは変わらないので index は元ソースとそのまま対応する。
    final masked = {
      for (final MapEntry(key: p, value: s) in sources.entries)
        p: maskComments(s),
    };
    // ⚠ **sink の数え上げは全ファイルを見てから。**呼び出し側のソースだけでは
    // 別ファイルで宣言された転送ラッパーが見えない。
    final sinks = breadcrumbSinks(masked.values);
    final offenders = <String>[];
    for (final MapEntry(key: path, value: source) in masked.entries) {
      if (allowedFiles.contains(path)) continue;
      for (final sink in sinks) {
        for (final (args, start) in callsOf(source, sink)) {
          final unsafe = unsafeInterpolations(args);
          if (unsafe.isEmpty) continue;
          // ⚠ 見逃し指示は**コメント**なので、こちらは潰す前のソースを見る。
          if (isMarked(sources[path]!, start)) continue;
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
          'sentry_flutter の DebugPrintIntegration は release と profile で'
          'debugPrint を差し替える。breadcrumb の message は _scrubBreadcrumb'
          '（data しか見ない）を通らないので、debugLogException / '
          '_logDevException を使うこと\n${offenders.join('\n')}',
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

  /// ⚠ **コメント内の括弧（#1020・Codex P2 の 6 巡目）。**本体に `}` を含む
  /// コメントがあると、括弧の対応付けが**そこで本体が終わった**と読む。以降の
  /// `debugPrint` が本体の外に出るので、そのラッパーは sink から漏れる。
  test('コメント内の括弧で本体を切らない', () {
    const withComment =
        'void logT(String m) {\n'
        "  // payload は {'key': value} の形\n"
        '  debugPrint(m);\n'
        '}';
    expect(breadcrumbSinks([withComment]), contains('logT'));

    expect(
      offendersIn({
        'a.dart': withComment,
        'b.dart': "void run() { logT('failed: \$e'); }",
      }),
      isNotEmpty,
    );
  });

  /// ⚠⚠ **breadcrumb を直接組み立てる経路（v1.60 リリース前レビュー）。**この
  /// 検査の動機は「`Breadcrumb.message` は `_scrubBreadcrumb` を通らない」こと
  /// なのに、sink の根が `debugPrint` だけだったため **`Breadcrumb(message: '$e')`
  /// を一度も見ていなかった**。`debugPrint` を併用しない限り視野に入らず、
  /// `chat_provider` の parse 失敗（＝チャット本文を持つ FormatException）が
  /// 素通しのまま緑だった。
  test('Breadcrumb を直接組み立てる経路も検査する', () {
    expect(
      offendersIn({
        'a.dart':
            'void watch() {\n'
            '  Sentry.addBreadcrumb(\n'
            "    Breadcrumb(category: 'x', message: e.toString()),\n"
            '  );\n'
            '}',
      }),
      isNotEmpty,
      reason: 'debugPrint を経由しない breadcrumb が見えないままだった',
    );

    // 型名だけを載せる正しい形は通す。
    expect(
      offendersIn({
        'a.dart':
            'void watch() {\n'
            "  Sentry.addBreadcrumb(Breadcrumb(message: e.runtimeType.toString()));\n"
            '}',
      }),
      isEmpty,
    );
  });

  /// ⚠ **Dart のブロックコメントは入れ子にできる。**最初の `*/` で止めると
  /// 外側の残りがコードとして読まれ、そこに `}` があれば本体が切れる。
  test('入れ子のブロックコメントで本体を切らない', () {
    const nested =
        'void logU(String m) {\n'
        '  /* outer /* inner */ } */\n'
        '  debugPrint(m);\n'
        '}';
    expect(breadcrumbSinks([nested]), contains('logU'));
  });

  /// ⚠ **仮引数の注釈。**`@Tag() String message` は `^` 固定の照合が `@` を見て
  /// 外れ、引数名が取れず**そのラッパーが黙って消える**。
  test('注釈つきの String 引数も拾う', () {
    const annotated =
        'void logV(@Tag() String message) => debugPrint(message);';
    expect(breadcrumbSinks([annotated]), contains('logV'));

    const namedAnnotated =
        'void logW({@Tag required String m}) => debugPrint(m);';
    expect(breadcrumbSinks([namedAnnotated]), contains('logW'));
  });

  /// 潰した副次効果。コメントアウトされたコードは実行されないので、違反として
  /// 数えても直しようが無い。
  test('コメントアウトされた呼び出しは違反にしない', () {
    expect(
      offendersIn({
        'a.dart': "void run() {\n  // debugPrint('failed: \$e');\n}",
      }),
      isEmpty,
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
