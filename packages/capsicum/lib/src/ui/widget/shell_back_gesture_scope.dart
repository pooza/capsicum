import 'package:flutter/material.dart';

/// shell の上（root の navigator）に画面が載っている間、shell の中のページに
/// Android の予測型バックを受けさせない (#1318)。
///
/// ⚠⚠ **予測型バックの検出器は「自分の navigator の中でいちばん上か」しか見ない**
/// （`_PredictiveBackGestureDetector` の `route.isCurrent && route.popGestureEnabled`）。
/// 画像ビューア（`/media`）は没入表示のため shell の外に置いてある (#834) ので、
/// その下で shell の中のいちばん上にいるルート（デッキの `/deck`・投稿の詳細など）も
/// 「current」のままになる。しかも binding は**受けると答えた検出器の全部**に
/// commit を配る。結果、画像を「戻る」ジェスチャーで閉じると、下の `/deck` まで
/// 閉じてタブ表示に落ちていた。⚠ ボタンの「戻る」は検出器を通らないので起きない。
///
/// shell のページが root で current でない間だけ、中のページ遷移を予測型バックを
/// 持たない [FadeForwardsPageTransitionsBuilder]（予測型バックの builder が
/// ジェスチャーの無いときに使う遷移そのもの）へ差し替える。上の画面の「戻る」は
/// 検出器に拾われず、ふつうの戻る（router の popRoute）としてその画面へ届く。
///
/// ⚠ 木の形は変えない（常に [Theme] で包み、中身の値だけ替える）。shell の
/// navigator を付け替えないため。ページの中身は `ModalRoute` の GlobalKey の下に
/// あるので、遷移の包みが替わってもデッキの状態は失われない。
class ShellBackGestureScope extends StatelessWidget {
  final Widget child;

  const ShellBackGestureScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    return Theme(
      data: isCurrent
          ? theme
          : theme.copyWith(
              pageTransitionsTheme: withoutPredictiveBack(
                theme.pageTransitionsTheme,
              ),
            ),
      child: child,
    );
  }
}

/// [theme] の予測型バックの builder を、ジェスチャーの無いときと同じ遷移に
/// 置き換えたもの。ほかの builder（iOS の Cupertino など）はそのまま。
@visibleForTesting
PageTransitionsTheme withoutPredictiveBack(PageTransitionsTheme theme) {
  return PageTransitionsTheme(
    builders: {
      for (final entry in theme.builders.entries)
        entry.key: switch (entry.value) {
          PredictiveBackPageTransitionsBuilder(:final fallbackColor) =>
            FadeForwardsPageTransitionsBuilder(backgroundColor: fallbackColor),
          PredictiveBackFullscreenPageTransitionsBuilder(
            :final fallbackColor,
          ) =>
            ZoomPageTransitionsBuilder(backgroundColor: fallbackColor),
          final other => other,
        },
    },
  );
}
