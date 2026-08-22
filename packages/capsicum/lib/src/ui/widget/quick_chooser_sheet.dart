import 'package:flutter/material.dart';

/// 「読み込んで一覧するクイックチューザ」のシート足場 (#982)。
///
/// ドロワー / 投稿画面から出るボトムシートのうち、**開いた瞬間に取りに行って
/// 一覧を出す**型のもの（投稿テンプレート・サーバー下書き等）が共有する外枠。
/// 見出し → 読み込み中 / 失敗 / 空 / 一覧 → 管理導線、という並びを 1 箇所に置く。
///
/// ⚠ **寄せたのは「足場」だけで、取得と並べ替えは各シートが持つ。** 取得先が
/// モロヘイヤだったり adapter だったり、並び順に使用履歴が絡んだりと、そこは
/// 共通化しても写しが減らない。
///
/// 3 つ目の写し（`_DraftSheet` が `_TemplateSheet` をほぼ丸写ししていた）が
/// 出た時点で寄せた。この形は片方だけ体裁を直すと「同じ操作なのに画面によって
/// 見え方が違う」になりやすい（[draftBodyPreview] 側の表記統一と同じ問題）。
class QuickChooserSheet extends StatelessWidget {
  const QuickChooserSheet({
    super.key,
    required this.title,
    required this.loading,
    required this.error,
    required this.emptyMessage,
    required this.items,
    this.footer,
  });

  /// 見出し。件数を添える場合は呼び出し側で組む（読み込み前・失敗時に数を
  /// 名乗らない出し分けがシートごとに違うため）。
  final String title;

  final bool loading;

  /// 失敗時に出す文言。⚠ **生の例外文字列を渡さない** (#867)。詳細は呼び出し側の
  /// `onLoadError` で計装する。
  final String? error;

  /// 一覧が空のときに出す文言。
  final String emptyMessage;

  /// 一覧の行。空リストなら [emptyMessage] を出す。
  final List<Widget> items;

  /// 一覧の下に区切り線付きで置く管理導線（「テンプレートを管理」等）。
  ///
  /// ⚠ **空のときも出る。** テンプレートは 1 件も無い状態から管理画面へ行けないと
  /// 詰むため。⚠ 逆に**読み込み中・失敗時は出さない**（一覧が確定していない間に
  /// 管理へ飛ばすと、失敗の原因が管理画面側にあるように見える）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final footer = this.footer;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else if (error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(error!))
          else ...[
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  emptyMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Flexible(child: ListView(shrinkWrap: true, children: items)),
            if (footer != null) ...[const Divider(height: 1), footer],
          ],
        ],
      ),
    );
  }
}
