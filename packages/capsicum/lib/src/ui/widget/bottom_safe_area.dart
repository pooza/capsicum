import 'package:flutter/material.dart';

/// `Scaffold` の body 下端に、システム UI 分の余白を確保する (#1037)。
///
/// ## なぜ要るか
///
/// `Scaffold` は body に safe-area inset を**自動では入れない**。加えて
/// targetSdk は `flutter.targetSdkVersion` に追従しており、**Android 15 以降は
/// edge-to-edge が強制でオプトアウトできない**。よって body はナビゲーション
/// バーの裏まで伸び、スクロールの最後の要素がボタンと重なる。
///
/// ユーザー報告 (#1037) はスレッド画面だったが、原因は画面固有ではない。
/// 下端に何も置いていない画面はすべて同じ形をしている。ホームのタイムラインで
/// 露見しなかったのは、`SimplePostBar` が `MediaQuery.padding.bottom` を自分で
/// 足していて**バーが inset を吸っていた**ため。
///
/// ## 多重に適用しても壊れない
///
/// 中身は `SafeArea` なので、`MediaQuery.removePadding` で消費した分を子から
/// 取り除く。つまり、この下にある `SimplePostBar` のような「自分で
/// `padding.bottom` を足すウィジェット」は 0 を読むことになり、**二重に余白が
/// 入らない**。入れ子にしても安全なので、画面ごとに「もう吸っているか」を
/// 調べずに包んでよい。
///
/// ## 上下左右のうち下だけなのはなぜか
///
/// 報告は下端の話で、左右まで広げると横持ち・ノッチ端末で既存レイアウトの
/// 横幅が変わる。影響範囲を報告の形に閉じるため下だけにしている。左右が要る
/// 画面が出てきたら、そこで個別に `SafeArea` を使う。
///
/// ## キーボードとの関係
///
/// 見るのは `viewPadding` ではなく `padding`（`SafeArea` の既定）。キーボードが
/// 出ている間はナビゲーションバーがその裏に隠れ、`padding.bottom` は 0 になる。
/// `viewPadding` を使うとキーボードの上に無駄な余白が残る。
///
/// ## 背景画像がある画面での置き場所
///
/// 背景 (`backgroundImageProvider`) を敷いている画面では、**背景の内側**に
/// 置く。外側に置くと背景がナビゲーションバーの手前で切れて、下端だけ地の色が
/// 出る。対象は `home_screen` と `post_detail_screen` の 2 つだけ。
class BottomSafeArea extends StatelessWidget {
  const BottomSafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SafeArea(top: false, left: false, right: false, child: child);
}
