import 'dart:io';

import 'package:capsicum/src/constants.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1027-D: Sentry の `phase` タグの綴りを 1 箇所に保つ。
///
/// ⚠⚠ **部分的な集約がいちばん悪い。**[ReactionPhase] は #976 で作られたが、
/// 入っていたのは `reaction_add` / `reaction_remove` の 2 つだけで、
/// **`'post_action'` は 7 箇所へ直書きのまま**だった（`post_tile` ×3 /
/// `cross_account_boost` / `post_actions` ×3）。定数が「ある」ように見えるので、
/// 次に足す人は直書き側を真似する。
///
/// タグ名を直すと Sentry 上で新旧が混在して母数が割れるため、綴りが散ることの
/// コストは書き換えの手間では済まない。
///
/// ## ⚠⚠ 2026-09-06: 検査自身が同じ構造をしていた (#1035-C3)
///
/// **検査が見ていたのは 3 リテラルの列挙だけ**（`post_action` / `reaction_add` /
/// `reaction_remove`）。`lib` には `compose_attachment` /
/// `redraft_resend_failed` / `startup_timeline` / `push_dedup` /
/// `push_registration` / `unregister` / `token_refresh` の直書きがあり、
/// **新しい値が 2 箇所目に複写されても無言**だった。
/// **doc が「部分的な集約がいちばん悪い」と書いている構造が、検査側に残っていた。**
///
/// 塞ぎ方は 2 つ:
///
/// 1. **禁止リテラルは列挙をやめ、[ReactionPhase] の宣言そのものから読む。**
///    定数を足したら自動で検査対象になる
/// 2. **「`'phase'` タグの値に同じリテラルが 2 箇所以上」を落とす。**どの綴りが
///    集約対象かを先に知らなくてよい ——「複写された」という事実だけで落ちる
void main() {
  const root = 'lib';

  /// 綴りを持ってよい唯一の場所。
  const declarationFile = 'lib/src/constants.dart';

  List<File> dartFiles() => Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.endsWith('.g.dart'))
      .toList();

  /// [ReactionPhase] が持っている綴りを**宣言から読む** (#1035-C3)。
  ///
  /// ⚠ **テスト側に列挙を書かない。**定数を足したときに検査へ書き足すのを
  /// 忘れると、そこから直書きが増え始める（この検査が塞ごうとしている形そのもの）。
  Map<String, String> declaredPhases() {
    final source = maskComments(File(declarationFile).readAsStringSync());
    final start = source.indexOf('class ReactionPhase');
    expect(
      start,
      isNonNegative,
      reason: 'ReactionPhase が見つからない。名前が変わったならこの検査のアンカーも直す',
    );
    final end = source.indexOf('\n}', start);
    final body = source.substring(start, end < 0 ? source.length : end);

    final out = <String, String>{};
    for (final m in RegExp(
      r"static\s+const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'([^']*)'",
    ).allMatches(body)) {
      out[m.group(2)!] = 'ReactionPhase.${m.group(1)}';
    }
    return out;
  }

  /// `setTag('phase', <値>)` の**値**を、`(値, ファイルパス)` で返す。
  List<(String, String)> phaseTagValues(Iterable<File> files) {
    final out = <(String, String)>[];
    final call = RegExp(r"setTag\(\s*'phase'\s*,");
    for (final file in files) {
      final source = maskComments(file.readAsStringSync());
      for (final m in call.allMatches(source)) {
        final rest = source.substring(m.end);
        final close = rest.indexOf(')');
        if (close < 0) continue;
        out.add((rest.substring(0, close).trim(), file.path));
      }
    }
    return out;
  }

  test('探索そのものが壊れていない', () {
    expect(dartFiles().length, greaterThan(50));
    expect(File(declarationFile).existsSync(), isTrue);

    // ⚠ **`setTag('phase', …)` を 1 つも見つけられないと、下の 2 本は
    // 「offenders が空」で緑になる。**呼び出しの形が変わったらここで落ちる。
    final values = phaseTagValues(dartFiles());
    expect(
      values.length,
      greaterThan(8),
      reason:
          "setTag('phase', …) の走査が空振りしている (#1035-C3)。"
          '呼び出しの書き方が変わったならこの検査も直す',
    );
  });

  test('定数と実際の綴りが一致している', () {
    // ⚠ 検査が古い綴りを守り続けないよう、実物と突き合わせる。
    expect(ReactionPhase.post, 'post_action');
    expect(ReactionPhase.add, 'reaction_add');
    expect(ReactionPhase.remove, 'reaction_remove');

    // 宣言から読めていることも固定する（読めないと下の検査が空振りする）。
    expect(
      declaredPhases().keys,
      containsAll(['post_action', 'reaction_add', 'reaction_remove']),
      reason: 'ReactionPhase の宣言を読めていない (#1035-C3)',
    );
  });

  test('phase の綴りを直書きしない (#1027-D)', () {
    final phases = declaredPhases();
    final offenders = <String>[];
    for (final file in dartFiles()) {
      final path = file.path;
      if (path == declarationFile) continue;
      final source = maskComments(file.readAsStringSync());
      for (final MapEntry(key: literal, value: constant) in phases.entries) {
        if (!source.contains("'$literal'")) continue;
        offenders.add("$path: '$literal' → $constant");
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'phase タグの綴りは constants.dart の ReactionPhase だけが持つ。'
          'タグ名を直すと Sentry 上で新旧が混在して母数が割れる'
          '\n${offenders.join('\n')}',
    );
  });

  test('phase タグの値に同じリテラルを 2 箇所以上書かない (#1035-C3)', () {
    // ⚠ **どの綴りが集約対象かを先に知らなくてよい。**「複写された」という
    // 事実だけで落ちるので、新しい値が増えても検査を書き足さずに効く。
    //
    // ⚠ 1 箇所だけの直書きは通す。集約する相手が無い段階で定数化を強制すると、
    // 「定数はあるが使い所は 1 つ」という別の散らかり方をする。
    final byLiteral = <String, Set<String>>{};
    for (final (value, path) in phaseTagValues(dartFiles())) {
      if (path == declarationFile) continue;
      final literal = RegExp(r"^'([^']*)'$").firstMatch(value)?.group(1);
      if (literal == null) continue; // 定数参照・変数は対象外
      byLiteral.putIfAbsent(literal, () => <String>{}).add(path);
    }

    final offenders = [
      for (final MapEntry(key: literal, value: paths) in byLiteral.entries)
        if (paths.length > 1) "'$literal' → ${paths.join(' / ')}",
    ];

    expect(
      offenders,
      isEmpty,
      reason:
          "phase タグの綴りが複写されている (#1035-C3)。'2 箇所目' が現れた時点で "
          'constants.dart の ReactionPhase へ寄せること。'
          '部分的な集約（定数はあるのに直書きも残る）がいちばん悪い'
          '\n${offenders.join('\n')}',
    );
  });

  group('判定ロジック自身 (#1035-C3)', () {
    // ⚠ 上の 2 本は「offenders が空なら緑」なので、判定が壊れても気づけない。
    test('コメント中の綴りは数えない', () {
      expect(
        maskComments("// setTag('phase', 'x')\nfinal a = 1;"),
        isNot(contains("'phase'")),
      );
    });

    test('文字列リテラル中の // でコメント扱いしない', () {
      // ⚠ #1035-C5。素朴な行コメント落としだと、同じ行に URL があると
      // 以降が丸ごと消えて検出対象が無くなる。
      expect(
        maskComments("final u = 'https://example.com'; setTag('phase', 'x');"),
        contains("setTag('phase', 'x')"),
      );
    });
  });
}
