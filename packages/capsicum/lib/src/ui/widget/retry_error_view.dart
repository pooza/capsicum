import 'package:flutter/material.dart';

/// 取得に失敗した画面に出す「本文 + 再試行」の共通ビュー (#916)。
///
/// ## なぜ共通化するか
///
/// 各画面が `.when(error:)` の中で同じ `Center > Padding > Column` を手書きして
/// おり、**再取得中の見た目がどこにも無かった**。riverpod 2.6.1 では、エラー
/// 状態の provider を `ref.invalidate` すると `AsyncError` に `isLoading: true`
/// が乗った状態になる（`AsyncLoading` にはならない）。`AsyncValue.when` の既定は
/// `skipLoadingOnRefresh: true` なので loading ブランチは**スキップされ、
/// error ブランチが再描画される**。つまり:
///
/// - 押しても画面が 1px も変わらない
/// - また同じ理由で失敗すると同じエラー文が再描画されるだけ
/// - 連打を抑止するガードも無く、押した数だけ重複リクエストが飛ぶ
///
/// 再取得自体は走っているので、**見え方だけの問題**。20 画面以上に同じものを
/// 撒くより、ここ一箇所で決める。
///
/// ## 使い方
///
/// [isRetrying] に **`.when` を呼んでいる `AsyncValue` の `isLoading`** を渡す。
///
/// ```dart
/// final notes = ref.watch(fooProvider);
/// return notes.when(
///   data: ...,
///   loading: ...,
///   error: (error, _) => RetryErrorView(
///     message: '読み込みに失敗しました\n$error',
///     isRetrying: notes.isLoading,
///     onRetry: () => ref.invalidate(fooProvider),
///   ),
/// );
/// ```
///
/// **`skipLoadingOnRefresh: false` を撒く方法は採らない。** それだと「データが
/// 出ている状態での引っ張って更新」まで loading に倒れ、更新のたびに一覧が
/// スピナーへ消える回帰になる。ここで見たいのは「**エラー状態からの**再取得中」
/// だけなので、error ブランチの中で `isLoading` を見るのが正しい粒度。
class RetryErrorView extends StatelessWidget {
  const RetryErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.isRetrying = false,
    this.retryLabel = '再試行',
    this.selectable = false,
  });

  /// 画面に出す本文。例外の要約を含めたい画面は、呼び出し側で組み立てて渡す
  /// （画面ごとに「どこに何を挟むか」が違うため、ここでは分解しない）。
  ///
  /// **URL やトークンが載りうる例外をそのまま入れないこと。** Misskey の URL には
  /// `?i=<accessToken>` が付く（#460）。生の `$error` は #900 のタイムアウト時に
  /// `The request took longer than 0:00:60 ... RequestOptions.receiveTimeout` の
  /// ような英語の開発者向け文をそのままユーザーに出す。呼び出し側は例外の要約に
  /// `summarizeOpError` を通すこと（チャット系・取得失敗系の各画面がそうしている・
  /// #960）。
  final String message;

  /// 再取得が進行中か。`AsyncValue.isLoading` をそのまま渡す。
  /// true の間はボタンを無効化してスピナーに差し替える。
  final bool isRetrying;

  final VoidCallback onRetry;

  final String retryLabel;

  /// 本文を選択・コピーできるようにするか。チャット系のようにサーバー由来の
  /// エラー文を控えてもらいたい画面で true にする（従来 `SelectableText` を
  /// 使っていた画面の挙動を保つため）。
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selectable)
              SelectableText(message, textAlign: TextAlign.center)
            else
              Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              // 再取得中は押せなくする。連打すると押した数だけ重複リクエストが
              // 飛んでいた (#916)。
              onPressed: isRetrying ? null : onRetry,
              // ラベルとスピナーを同じ箱に入れて、切り替えでボタンの寸法が
              // 変わらないようにする（押した瞬間に下の要素がずれない）。
              child: isRetrying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
