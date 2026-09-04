import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
void main() {
  const screens = {
    'user_list_screen.dart': 'ブロック / ミュート / フォローリクエストの土台',
    'post_list_screen.dart': '引用の一覧',
    'followed_hashtags_screen.dart': 'フォロー中のハッシュタグ',
  };

  for (final entry in screens.entries) {
    group('${entry.key}（${entry.value}）', () {
      final source = File('lib/src/ui/screen/${entry.key}').readAsStringSync();

      test('失敗を保持して「0 件」と描き分ける', () {
        expect(
          source.contains('Object? _error'),
          isTrue,
          reason: '取得失敗を保持していない。失敗が「0 件」として描かれる',
        );
        expect(
          source.contains('_error != null'),
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
        expect(
          source.contains(
            'setState(() => _loading = true);\n                  await',
          ),
          isFalse,
          reason:
              'onRefresh で _loading を立てると三項の分岐が変わり、'
              'RefreshIndicator ごとアンマウントされてスピナーが飛ぶ',
        );
      });

      test('継続判定に件数を使わない', () {
        // サーバーはフィルタで件数を減らしたうえで next リンクを返す
        // （Mastodon の quotes_controller は records_continue をフィルタ前に決める）。
        expect(
          source.contains('>= _pageSize'),
          isFalse,
          reason:
              '件数で継続を判定すると 2 ページ目以降が永久に見えなくなる。'
              'nextCursor の有無だけで判定すること',
        );
      });
    });
  }
}
