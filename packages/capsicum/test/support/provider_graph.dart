/// provider の参照関係をソースから組み立てる (#1097)。
///
/// `provider_scope_dependencies_guard_test` が使う。**Riverpod のスコープ上書き
/// （デッキのカラムごとのアカウント・案 S）で、宣言漏れの provider が「ルートの
/// 現在のアカウント」で黙って動く**のを、release でも効く形で止めるため。
///
/// ## 何を provider の「本体」と見なすか
///
/// - トップレベルの `final <名前> = …Provider…;` の右辺
/// - 右辺が名前で参照するクラスの本体。`<クラス>.new` の Notifier（`build()` や
///   `loadMore()` で `ref.read(...)` している分）と、`(ref) => Foo(ref)` で `ref` を
///   受け取るサービスクラスの両方
///
/// ## ⚠ 拾えないもの
///
/// - `ref` を引数で受け取る**関数やヘルパクラスの中**の参照（例: `foo(ref)` の中で
///   `ref.read(currentAccountProvider)`）。見つけたら本体側へ寄せるか、ここを広げる
library;

import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'dart_source.dart';

/// provider 1 つぶんの解析結果。
class ProviderNode {
  ProviderNode({
    required this.name,
    required this.file,
    required this.line,
    required this.endLine,
    required this.declaredDependencies,
    required this.references,
  });

  final String name;
  final String file;

  /// 宣言の行（1 始まり）。失敗メッセージで場所を示すため。
  final int line;

  /// 宣言の終わり（`;` のある行）。`dependencies:` を足す位置を示すため。
  final int endLine;

  /// `dependencies: [...]` に書かれた名前。**書かれていなければ null**。
  final Set<String>? declaredDependencies;

  /// 本体（右辺 + Notifier クラス）が参照している他の provider の名前。
  /// `dependencies:` の中身は数えない。
  final Set<String> references;
}

/// 解析結果の全体。
class ProviderGraph {
  ProviderGraph(this.nodes);

  final Map<String, ProviderNode> nodes;

  /// [roots] を直接・間接に参照する provider の閉包（[roots] と、
  /// `dependencies:` を宣言している provider を含む）。
  ///
  /// ⚠ **`dependencies:` を宣言した provider は、読む側も宣言が要る**
  /// （Riverpod 2.6.1 `element.dart` の `_debugAssertCanDependOn`）ので、宣言済みの
  /// ものも起点に含める。
  ///
  /// [rootOnly] は「意図的にルートスコープ専用」の provider。閉包に入らず、
  /// そこから先へも伝播しない（読む側に宣言を求めない）。
  Set<String> scopedClosure(
    Set<String> roots, {
    Set<String> rootOnly = const {},
  }) {
    final scoped = <String>{
      ...roots,
      for (final n in nodes.values)
        if (n.declaredDependencies != null && !rootOnly.contains(n.name))
          n.name,
    };
    var changed = true;
    while (changed) {
      changed = false;
      for (final n in nodes.values) {
        if (scoped.contains(n.name) || rootOnly.contains(n.name)) continue;
        if (n.references.any(scoped.contains)) {
          scoped.add(n.name);
          changed = true;
        }
      }
    }
    return scoped;
  }

  /// 宣言が足りない provider → 足りない名前。[roots] 自身は対象外。
  Map<String, Set<String>> missingDependencies(
    Set<String> roots, {
    Set<String> rootOnly = const {},
  }) {
    final scoped = scopedClosure(roots, rootOnly: rootOnly);
    final result = SplayTreeMap<String, Set<String>>();
    for (final name in scoped) {
      if (roots.contains(name)) continue;
      final node = nodes[name]!;
      final required = node.references.where(scoped.contains).toSet();
      final missing = required.difference(node.declaredDependencies ?? {});
      if (missing.isNotEmpty) result[name] = missing;
    }
    return result;
  }
}

/// `lib/` 配下の Dart ソースを読んで [ProviderGraph] を作る。
ProviderGraph buildProviderGraphFromDirectory(String dir) {
  final sources = <String, String>{
    for (final f in Directory(dir).listSync(recursive: true))
      if (f is File && f.path.endsWith('.dart')) f.path: f.readAsStringSync(),
  };
  return buildProviderGraph(sources);
}

final _declaration = RegExp(r'^final\s+(\w+)\s*=', multiLine: true);
final _providerConstructor = RegExp(r'\b\w*Provider\b\s*[.<(]');
final _notifierNew = RegExp(r'\b([A-Z]\w*)\.new\b');
final _refPassedTo = RegExp(r'\b([A-Z]\w*)\s*\(\s*ref\b');
final _dependencies = RegExp(r'\bdependencies\s*:\s*\[([^\]]*)\]');
final _identifier = RegExp(r'\b[A-Za-z_]\w*\b');

/// パス → ソースから [ProviderGraph] を作る（合成ソースのテスト用に公開）。
ProviderGraph buildProviderGraph(Map<String, String> sources) {
  final masked = {
    for (final e in sources.entries) e.key: maskStrings(maskComments(e.value)),
  };

  // Notifier クラスの本体（クラス名 → 本体）。
  final classBodies = <String, String>{};
  final classDecl = RegExp(r'\bclass\s+([A-Z]\w*)\b[^{;]*\{');
  for (final src in masked.values) {
    for (final m in classDecl.allMatches(src)) {
      final end = _matchingBrace(src, m.end - 1);
      classBodies[m.group(1)!] = src.substring(m.end, end);
    }
  }

  // 1 周目: 名前と右辺を集める。
  final raw = <String, ({String file, int line, int endLine, String body})>{};
  for (final e in masked.entries) {
    for (final m in _declaration.allMatches(e.value)) {
      final end = _statementEnd(e.value, m.end);
      final body = e.value.substring(m.end, end);
      if (!_providerConstructor.hasMatch(body)) continue;
      int lineOf(int offset) =>
          '\n'.allMatches(e.value.substring(0, offset)).length + 1;
      raw[m.group(1)!] = (
        file: e.key,
        line: lineOf(m.start),
        endLine: lineOf(end),
        body: body,
      );
    }
  }

  // 2 周目: 参照を解決する。
  final nodes = <String, ProviderNode>{};
  for (final e in raw.entries) {
    var body = e.value.body;
    Set<String>? declared;
    final dep = _dependencies.firstMatch(body);
    if (dep != null) {
      declared = {
        for (final part in dep.group(1)!.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      };
      body = body.replaceRange(dep.start, dep.end, '');
    }
    // 右辺が作るクラスの本体も見る。`Foo.new`（Notifier）と `(ref) => Foo(ref)`
    // （ref を受け取るサービスクラス）はどちらも中で `ref.read(...)` する。
    // ⚠ 名前で出てくるクラスを全部読むと、ルーター定義が参照する**画面ウィジェット**
    // まで読んでしまう。ウィジェットは自分の位置のスコープで解決するので、
    // provider の依存に数えてはいけない。
    final scanned = StringBuffer(body);
    final seenClasses = <String>{};
    for (final c in [
      ..._notifierNew.allMatches(body),
      ..._refPassedTo.allMatches(body),
    ]) {
      final name = c.group(1)!;
      if (!seenClasses.add(name)) continue;
      final classBody = classBodies[name];
      if (classBody != null) scanned.write(classBody);
    }
    final references = {
      for (final id in _identifier.allMatches(scanned.toString()))
        if (raw.containsKey(id.group(0)) && id.group(0) != e.key) id.group(0)!,
    };
    nodes[e.key] = ProviderNode(
      name: e.key,
      file: e.value.file,
      line: e.value.line,
      endLine: e.value.endLine,
      declaredDependencies: declared,
      references: references,
    );
  }
  return ProviderGraph(nodes);
}

/// [start] 以降で、括弧の深さ 0 の `;` の位置（無ければ末尾）。
int _statementEnd(String src, int start) {
  var depth = 0;
  for (var i = start; i < src.length; i++) {
    final ch = src[i];
    if (ch == '(' || ch == '[' || ch == '{') depth++;
    if (ch == ')' || ch == ']' || ch == '}') depth = math.max(0, depth - 1);
    if (ch == ';' && depth == 0) return i;
  }
  return src.length;
}

/// [open] の `{` に対応する `}` の位置（無ければ末尾）。
int _matchingBrace(String src, int open) {
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return src.length;
}
