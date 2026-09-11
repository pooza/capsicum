import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// `dispose()` の中で provider を書き換えない。
///
/// ## なぜ落とすのか
///
/// Riverpod は `build` / `initState` / `dispose` / `didUpdateWidget` /
/// `didChangeDependencies` の最中の provider 書き換えを禁じており、破ると
/// `Tried to modify a provider while the widget tree was building` を投げる。
///
/// ⚠⚠ **「解除が漏れる」では済まない。**`dispose` は `_InactiveElements._unmount`
/// の再帰の中で呼ばれるので、ここで投げると**残りの unmount が丸ごと打ち切られる**。
/// 半分だけ畳まれた element が木に残り、後続のフレームで
///
/// - `element._lifecycleState == _ElementLifecycle.inactive` の assert 失敗
/// - `Duplicate GlobalKey detected in widget tree`
/// - `Bad state: Cannot use "ref" after the widget was disposed`
///
/// が連鎖して**赤画面**になる。実際に `HomeScreen.dispose` の
/// `refreshNotifier.state = null`（#834 でデスクトップメニューの解除として入れた）
/// が、既ログインのアカウントを足し直したときに踏まれた。
///
/// ## 逃がし方
///
/// 書き換えを `addPostFrameCallback` などでフレームの外へ出す。⚠ **同一性の判定も
/// 遅延先で行うこと。**新しい画面は `initState` の post-frame で登録するので、
/// 先に判定して遅延先で書くと**新しい登録を消す**。
void main() {
  /// `void dispose() {` の本体を（波括弧の対応で）切り出す。
  ///
  /// ⚠ コメントは [maskComments] で潰してから数える。本体に
  /// `// payload は {'key': v} の形` のような行があると、対応付けがそこで
  /// 終わったことになって以降を見落とす。
  ///
  /// ⚠ **文字列リテラルの中身も [maskStrings] で潰す。**`maskComments` はリテラル
  /// を残すので、`log('notifier.state = null')` のような説明文を違反として数える。
  List<String> disposeBodies(String source) {
    final code = maskStrings(maskComments(source));
    final bodies = <String>[];
    final head = RegExp(r'void\s+dispose\s*\(\s*\)\s*(?:async\s*)?\{');
    for (final m in head.allMatches(code)) {
      var depth = 1;
      var i = m.end;
      for (; i < code.length && depth > 0; i++) {
        if (code[i] == '{') depth++;
        if (code[i] == '}') depth--;
      }
      bodies.add(code.substring(m.end, i - 1));
    }
    return bodies;
  }

  /// フレームの外へ逃がした呼び出しの**引数まるごと**を落とす。
  ///
  /// ⚠ **行単位で消さない。**`addPostFrameCallback((_) {` … `});` は複数行に
  /// またがるので、括弧の対応で消す必要がある。
  const deferrals = [
    'addPostFrameCallback',
    'addPersistentFrameCallback',
    'scheduleMicrotask',
    'microtask',
    'delayed',
  ];

  String stripDeferred(String body) {
    var out = body;
    for (final name in deferrals) {
      while (true) {
        final at = out.indexOf('$name(');
        if (at == -1) break;
        var depth = 0;
        var i = at + name.length;
        for (; i < out.length; i++) {
          if (out[i] == '(') depth++;
          if (out[i] == ')') {
            depth--;
            if (depth == 0) {
              i++;
              break;
            }
          }
        }
        out = out.replaceRange(at, i, '/*deferred*/');
      }
    }
    return out;
  }

  /// provider の書き換え。`==` の比較は当てない。
  final write = RegExp(r'\.state\s*(?:=[^=]|\+\+|--)|\.update\s*\(');

  List<String> offendingBodies(String source) => [
    for (final body in disposeBodies(source))
      if (write.hasMatch(stripDeferred(body))) body,
  ];

  List<File> libFiles() => [
    for (final entity in Directory('lib').listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart')) entity,
  ];

  test('⚠ 走査が空振りしていない（dispose の本体を実際に拾えている）', () {
    // ⚠⚠ **`expect(offenders, isEmpty)` は何も見ていなくても通る。**
    // 「違反が無い」の前に「対象を見ている」を固定する。
    var found = 0;
    for (final file in libFiles()) {
      found += disposeBodies(file.readAsStringSync()).length;
    }
    expect(
      found,
      greaterThan(20),
      reason: 'lib 配下の dispose を拾えていない。正規表現か波括弧の対応を確認すること',
    );

    // 置き換え後の形が実在すること（＝直した実物を見ている）。
    final home = disposeBodies(
      File('lib/src/ui/screen/home_screen.dart').readAsStringSync(),
    );
    expect(home, isNotEmpty, reason: 'HomeScreen の dispose を見失っている');
    expect(
      home.any((b) => b.contains('addPostFrameCallback')),
      isTrue,
      reason: 'HomeScreen の解除がフレームの外へ出ていない（直った形が消えている）',
    );
  });

  test('⚠ 歯があること: 修正前の HomeScreen.dispose を食わせると落ちる', () {
    // 実物の「穴」をそのまま置く。合成テストは自分が想定した書き方しか並べない
    // ので、**実在した形**で歯を確かめる（#1062 のガード初版はこれを飛ばして
    // 修正対象そのものを取りこぼした）。
    const before = '''
class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void dispose() {
    final refreshNotifier = _refreshNotifier;
    if (refreshNotifier != null &&
        refreshNotifier.state == _refreshCurrentTimeline) {
      refreshNotifier.state = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
''';
    expect(offendingBodies(before), hasLength(1));
  });

  group('判定ロジック', () {
    test('遅延させた書き換えは当てない（直した形）', () {
      const after = '''
void dispose() {
  final refreshNotifier = _refreshNotifier;
  final ownRefresh = _refreshCurrentTimeline;
  if (refreshNotifier != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!refreshNotifier.mounted) return;
      if (refreshNotifier.state == ownRefresh) {
        refreshNotifier.state = null;
      }
    });
  }
  super.dispose();
}
''';
      expect(offendingBodies(after), isEmpty);
    });

    test('比較（==）は当てない', () {
      const src = '''
void dispose() {
  if (notifier.state == _mine) log('still mine');
  super.dispose();
}
''';
      expect(offendingBodies(src), isEmpty);
    });

    test('update() での書き換えも当てる', () {
      const src = '''
void dispose() {
  ref.read(p.notifier).update((v) => null);
  super.dispose();
}
''';
      expect(offendingBodies(src), hasLength(1));
    });

    test('コメント / 文字列リテラルの中は当てない', () {
      const src = '''
void dispose() {
  // notifier.state = null; はここでは書けない
  log('notifier.state = null');
  super.dispose();
}
''';
      expect(offendingBodies(src), isEmpty);
    });

    test('dispose の外（initState）の書き換えは当てない', () {
      const src = '''
void initState() {
  super.initState();
  notifier.state = _mine;
}

void dispose() {
  super.dispose();
}
''';
      expect(offendingBodies(src), isEmpty);
    });

    test('⚠ 本体のコメントに閉じ括弧があっても本体を切り詰めない', () {
      const src = '''
void dispose() {
  // payload は {'key': value} の形
  notifier.state = null;
  super.dispose();
}
''';
      expect(offendingBodies(src), hasLength(1));
    });
  });

  test('lib 配下の dispose は provider を書き換えていない', () {
    final offenders = <String>[];
    for (final file in libFiles()) {
      if (offendingBodies(file.readAsStringSync()).isNotEmpty) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'dispose 中の provider 書き換えは unmount を打ち切り、赤画面になる。'
          'addPostFrameCallback でフレームの外へ出すこと',
    );
  });
}
