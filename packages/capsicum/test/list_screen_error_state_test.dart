import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// リリース前レビュー 🔴 の回帰テスト（v1.63）。
///
/// ⚠⚠ **一覧画面が「取得失敗」を「0 件」として描いていた。**「ブロック中の
/// ユーザーはいません」「未処理のフォローリクエストはありません」と、
/// **アカウントの状態について誤った事実を断言する**形だった。ブロックが消えた
/// と誤解して再ブロックしに行く、申請が取り下げられたと読む、といった実害が出る。
///
/// ⚠ **同じリリースの #1041 で検索に「0 件と引けないを区別する」を入れながら、
/// 隣で落としていた。**3 観点のレビューが独立に同じ指摘を出した。
///
/// あわせて、`RefreshIndicator` の `onRefresh` で `_loading` を立てると
/// **indicator ごとアンマウントされて引っ張ったスピナーが即座に消える**問題も
/// 固定する。
///
/// ## ⚠⚠ 2026-09-07: 見る場所が変わった (#1083-A)
///
/// ページングの骨格を [CursorPagedListView] へ集約したので、**この振る舞いの
/// 実装は 1 箇所**になった。検査も 2 段に分ける:
///
/// 1. **正本（`cursor_paged_list_view.dart`）が振る舞いを持っていること**
/// 2. **各画面がそこへ委譲していること**（＝ 自前のページングへ戻っていない）
///
/// ⚠ **2 を落とすと意味が無い。**正本だけ見ていると、画面が自前実装へ戻った
/// ときに**正本は緑のまま**素通りする。#1083-A が直したのはまさに
/// 「汎用画面を作りながら隣で手書きが増えた」形なので、**再発は「使わなく
/// なること」として現れる。**
void main() {
  const canonical = 'lib/src/ui/widget/cursor_paged_list_view.dart';

  /// 委譲する側。`(パス, 説明)`。
  const screens = {
    'user_list_screen.dart': 'ブロック / ミュート / フォローリクエストの土台',
    'post_list_screen.dart': '引用の一覧',
    'followed_hashtags_screen.dart': 'フォロー中のハッシュタグ',
  };

  group('正本: $canonical', () {
    final source = File(canonical).readAsStringSync();

    test('探索が空振りしていない', () {
      expect(File(canonical).existsSync(), isTrue);
      expect(source.length, greaterThan(2000));
    });

    test('失敗を保持して「0 件」と描き分ける', () {
      expect(
        source.contains('Object? _error'),
        isTrue,
        reason: '取得失敗を保持していない。失敗が「0 件」として描かれる',
      );
      expect(
        source.contains('if (error != null)'),
        isTrue,
        reason: '失敗を保持しても描画で分岐していない',
      );
    });

    test('失敗時に再試行できる', () {
      expect(
        source.contains('RetryErrorView'),
        isTrue,
        reason:
            '初回ロードが失敗すると復帰手段が無い。'
            'empty ブランチは RefreshIndicator の外なので引っ張って更新もできない',
      );
      // 例外をそのまま出さない（URL やトークンが載りうる）。
      expect(
        source.contains('summarizeOpError'),
        isTrue,
        reason: '生の例外を UI に出している。summarizeOpError を通すこと',
      );
    });

    test('引っ張って更新で RefreshIndicator を消さない', () {
      // `onRefresh` は `_loading` を立てない `load` を直に渡す。
      expect(
        maskComments(source),
        contains('onRefresh: load'),
        reason:
            'onRefresh で _loading を立てると三項の分岐が変わり、'
            'RefreshIndicator ごとアンマウントされてスピナーが飛ぶ',
      );
    });

    test('継続判定に件数を使わない', () {
      // サーバーはフィルタで件数を減らしたうえで next リンクを返す
      // （Mastodon の quotes_controller は records_continue をフィルタ前に決める）。
      final code = maskComments(source);
      expect(
        code.contains('_hasMore = result.nextCursor != null'),
        isTrue,
        reason: 'nextCursor の有無で判定していない',
      );
      expect(
        code.contains('>= _pageSize'),
        isFalse,
        reason:
            '件数で継続を判定すると 2 ページ目以降が永久に見えなくなる。'
            'nextCursor の有無だけで判定すること',
      );
    });

    test('世代カウンタで古いページを捨てる (#1083-B)', () {
      final code = maskComments(source);
      expect(code.contains('int _generation = 0'), isTrue);
      expect(
        code.contains('generation != _generation'),
        isTrue,
        reason:
            '引っ張って更新と追加読み込みが交差すると、新しい 1 ページ目に'
            '古い 2 ページ目が連結され、カーソルも巻き戻る',
      );
      expect(
        code.contains('_loadingMore = false'),
        isTrue,
        reason: 'load が in-flight の追加読み込みを無効化したことを UI に反映していない',
      );
    });

    test('プリフェッチ閾値は 1 箇所で定数として持つ (#1083-A)', () {
      // ⚠ 画面ごとに 600 / 400 と揺れていたのを集約した回。定数に名前を
      // 付けておかないと、また書き写されて揺れる。
      expect(maskComments(source), contains('_prefetchThreshold'));
    });
  });

  group('委譲: 自前のページングへ戻っていないこと (#1083-A)', () {
    for (final entry in screens.entries) {
      test('${entry.key}（${entry.value}）', () {
        final code = maskComments(
          File('lib/src/ui/screen/${entry.key}').readAsStringSync(),
        );

        expect(
          code,
          contains('CursorPagedListView'),
          reason:
              '${entry.key} が集約先を使っていない (#1083-A)。'
              '自前でページングを書くと、失敗の描き分け・世代カウンタ・'
              'プリフェッチ閾値がまた画面ごとに揺れる',
        );

        // ⚠ **骨格の持ち物が画面へ戻っていないこと。**「使っている」だけだと、
        // 併存（片方だけ使う）を見逃す。
        for (final own in const [
          'Object? _error',
          '_loadingMore',
          '_nextCursor',
          'int _generation',
          'maxScrollExtent',
        ]) {
          expect(
            code.contains(own),
            isFalse,
            reason:
                '${entry.key} が `$own` を自前で持っている。'
                'ページングの状態は CursorPagedListView に寄せること',
          );
        }
      });
    }
  });
}
