import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1107: `state.extra` を必須で読まない。
///
/// ⚠⚠ **`extra` は画面を開いたまま null に落ちうる。**go_router は
/// `refreshListenable` が鳴るたびに RouteMatchList をシリアライズ経由で組み直し、
/// `extraCodec` が無いと `json.encoder.convert(extra)` に掛ける。JSON にできない
/// 値（モデルのインスタンス・クロージャ）が 1 つでもあると extra は丸ごと null に
/// なる（#1057 で実測・`router_login_args_test`）。Android のプロセス復帰でも
/// route だけが復元されて同じ形になる（#1083-F）。
///
/// そのとき `state.extra!` / `state.extra as T`（`?` なし）は投げるので、
/// **その画面を開いていた利用者のアプリが落ちる。**`is!` で弾いて
/// `_goHomeAfterBuild` へ落とす形に揃えた。この検査はその書き方が戻ってくる
/// 経路を塞ぐ。
void main() {
  final libDir = Directory('lib');
  final sources = libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  /// `state.extra` を必須で読んでいる行を返す。
  ///
  /// 当てるのは 2 形:
  /// - `state.extra!`
  /// - `state.extra as T`（型の直後に `?` が無い）。⚠ **`!` を外して
  ///   `as GalleryPost` と書いても null で投げる**ので同じ扱い（実物にあった）
  ///
  /// ⚠ コメントは潰す（説明文の `state.extra!` で当たると、直しようがない）。
  List<String> offendersIn(String source) {
    final masked = maskComments(source);
    final bang = RegExp(r'state\.extra\s*!');
    // 型引数 `<...>` は中にカンマと空白を含むので、`>` までを 1 塊で読む。
    final cast = RegExp(r'state\.extra\s+as\s+[A-Za-z_]\w*(?:<[^;]*?>)?(\??)');
    final hits = <String>[];
    final lines = masked.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final required =
          bang.hasMatch(line) ||
          cast.allMatches(line).any((m) => m.group(1)!.isEmpty);
      if (required) hits.add('${i + 1}: ${line.trim()}');
    }
    return hits;
  }

  group('⚠ 走査が空振りしていない', () {
    test('lib の走査が実際にファイルを拾っている', () {
      expect(sources.length, greaterThan(100));
    });

    test('router.dart は state.extra を読んでおり、受け皿を使っている', () {
      // ⚠ **「違反が無い」だけを見ると、「extra を読むルートが無い」でも緑に
      // なる。**置き換え後の形が実在することを数で押さえる。
      final router = File('lib/src/router.dart').readAsStringSync();
      final masked = maskComments(router);
      expect(
        RegExp(r'state\.extra\b').allMatches(masked).length,
        greaterThan(20),
      );
      expect(
        RegExp(
          r'return _goHomeAfterBuild\(context\);',
        ).allMatches(masked).length,
        greaterThanOrEqualTo(12),
        reason: '#1083-F の 2 本（/users・/posts）+ #1107 の 10 本',
      );
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('必須で読む形は当たる', () {
      const samples = [
        'final post = state.extra! as Post;',
        'final extra = state.extra! as Map<String, dynamic>;',
        'CollectionDetailScreen(collectionId: state.extra! as String),',
        'final post = state.extra as GalleryPost;',
        'final m = state.extra as Map<String, dynamic>;',
        'final x = state.extra!;',
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isNotEmpty, reason: sample);
      }
    });

    test('当ててはいけない形は当たらない', () {
      const samples = [
        // 受け皿へ落とす形（これが正しい書き方）
        'final post = state.extra;',
        'if (post is! Post) return _goHomeAfterBuild(context);',
        // nullable キャスト
        'final page = state.extra as Page?;',
        'final extra = state.extra as Map<String, dynamic>?;',
        "final nextRoute = state.extra as String? ?? '/server';",
        // そのまま渡す
        'withExtraProviderScope(state.extra, const ProfileEditScreen()),',
        // コメントでの言及
        '// `state.extra!` のままだと落ちる',
        '/// `state.extra as T` は投げる',
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isEmpty, reason: sample);
      }
    });
  });

  group('⚠⚠ 歯があることを実物で確かめる', () {
    test('修正前の router.dart は 10 箇所とも当たる', () {
      // ⚠⚠ **SHA で固定する。**`HEAD:` だと修正がコミットされた瞬間に修正後の
      // ファイルが出てきて当たらなくなる。`60ff9b23` = #1107 の直前。
      // `analyze.yml` は `fetch-depth: 0` なので CI でも引ける。
      final before = Process.runSync('git', [
        'show',
        '60ff9b23:packages/capsicum/lib/src/router.dart',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      final source = before.stdout as String;
      expect(
        source,
        contains('state.extra! as AnnictReviewScreenArgs'),
        reason: '取り出したのが本当に修正前のファイルであること',
      );
      // 9 箇所の `!` + `as GalleryPost`（`!` 無しでも投げる形）。
      expect(offendersIn(source), hasLength(10));
    });
  });

  test('lib に state.extra を必須で読む箇所が無い', () {
    final offenders = <String>[];
    for (final file in sources) {
      for (final hit in offendersIn(file.readAsStringSync())) {
        offenders.add('${file.path} $hit');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'state.extra は refresh / プロセス復帰で null に落ちる (#1107)。'
          '`is!` で弾いて _goHomeAfterBuild(context) へ落とすこと',
    );
  });
}
