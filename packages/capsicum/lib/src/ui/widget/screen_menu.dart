import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_menu_model.dart';

/// デスクトップメニューバーを「表示中の画面」に連動させるための枠組み (#835)。
///
/// #713 / #841 で作ったメニューはどの画面でも同じ固定項目で、画面上でできる操作
/// （メディアビューアの保存・次/前、スレッドの操作 等）がメニューから辿れない。
/// ここでは各画面が **自分のメニュー貢献を宣言する** 仕組みだけを用意し、項目は
/// 画面ごとに少しずつ足していく（本 issue の「急がない・段階導入」方針）。
///
/// 設計上の決めごと:
///
/// - 貢献は **1 画面 = 1 サブメニュー**。既存メニューの中身へ差し込む形にすると
///   挿入位置の取り決めが画面側に漏れるため、まずは独立した見出しに閉じる。
/// - 宣言はスタック。ルートを push すると上に積まれ、**最前面の 1 つだけ**が
///   メニューに出る。pop すれば下の画面の貢献に戻る。
/// - モデルは [MenuEntry]（#841 の単一モデル）をそのまま使う。macOS の
///   `PlatformMenuBar` と Windows/Linux の `MenuBar` は既存の 2 レンダラが
///   変換するので、画面側はプラットフォームを意識しない。
@immutable
class ScreenMenuContribution {
  const ScreenMenuContribution({required this.label, required this.entries});

  /// メニューバーに出る見出し（例: 「メディア」「スレッド」）。
  final String label;

  final List<MenuEntry> entries;
}

/// 画面メニュー貢献のスタック。token は宣言元 [ScreenMenu] の同一性。
class ScreenMenuRegistry
    extends
        Notifier<List<({Object token, ScreenMenuContribution contribution})>> {
  @override
  List<({Object token, ScreenMenuContribution contribution})> build() =>
      const [];

  /// 宣言を登録（同じ token の再登録は差し替え、順序は最前面へ移す）。
  void register(Object token, ScreenMenuContribution contribution) {
    state = [
      ...state.where((e) => e.token != token),
      (token: token, contribution: contribution),
    ];
  }

  /// 宣言を取り下げる。既に別の画面に置き換わっていても、自分の分だけ落とす。
  void unregister(Object token) {
    if (!state.any((e) => e.token == token)) return;
    state = state.where((e) => e.token != token).toList();
  }
}

final screenMenuRegistryProvider =
    NotifierProvider<
      ScreenMenuRegistry,
      List<({Object token, ScreenMenuContribution contribution})>
    >(ScreenMenuRegistry.new);

/// いまメニューに出すべき画面メニュー（最前面の 1 つ）。宣言が無ければ null。
final activeScreenMenuProvider = Provider<ScreenMenuContribution?>(
  (ref) => ref.watch(screenMenuRegistryProvider).lastOrNull?.contribution,
);

/// 画面が自分のメニューを宣言するための widget (#835)。画面本体を包んで使う。
///
/// マウント中だけ宣言が有効になり、pop / 画面差し替えで自動的に取り下げられる。
/// デスクトップ以外でも安全（メニューバー自体が描かれないので何も起きない）。
class ScreenMenu extends ConsumerStatefulWidget {
  const ScreenMenu({
    super.key,
    required this.label,
    required this.entries,
    required this.child,
  });

  final String label;
  final List<MenuEntry> entries;
  final Widget child;

  @override
  ConsumerState<ScreenMenu> createState() => _ScreenMenuState();
}

class _ScreenMenuState extends ConsumerState<ScreenMenu> {
  /// 登録の同一性。widget が作り直されても State は生き続けるので、これを token に
  /// すれば「同じ画面の宣言」を差し替えとして扱える。
  late final Object _token = Object();

  /// dispose では `ref` を使えない（disposed 後の read は StateError）ため、
  /// 取り下げ先の notifier を先に控えておく。registry は autoDispose ではない
  /// ので、この参照はアプリの生存中ずっと有効。
  late final ScreenMenuRegistry _registry;

  @override
  void initState() {
    super.initState();
    _registry = ref.read(screenMenuRegistryProvider.notifier);
    _publish();
  }

  @override
  void didUpdateWidget(ScreenMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 中身が変わっていないなら触らない（毎フレームの再登録で メニューバーを
    // 無駄に rebuild させない）。項目リストは画面側で作り直されるため、
    // 同一性で軽く判定する。
    if (widget.label == oldWidget.label &&
        identical(widget.entries, oldWidget.entries)) {
      return;
    }
    _publish();
  }

  /// provider の更新は build 中に行えないため、フレーム後に回す。
  void _publish() {
    final contribution = ScreenMenuContribution(
      label: widget.label,
      entries: widget.entries,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _registry.register(_token, contribution);
    });
  }

  @override
  void dispose() {
    // provider の変更はウィジェットのライフサイクル中に行えない（Riverpod が
    // assert する）。取り下げも登録と同じくフレーム後に回す。1 フレームだけ
    // 前の画面のメニューが残るが、メニューバーの見た目としては問題ない。
    final registry = _registry;
    final token = _token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        registry.unregister(token);
      } catch (_) {
        // アプリ終了時など、既に container ごと破棄されている場合。
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 固定メニュー [model] に、表示中の画面の貢献を差し込む (#835)。
///
/// 位置は「表示」の後・「ウインドウ」の前。画面固有の操作は表示系の近くにあるのが
/// 自然で、かつ OS 由来のウインドウ操作は末尾に置いたままにしたいため。該当の
/// 見出しが無いモデル（将来の構成変更）では末尾に足す。
List<MenuSubmenuEntry> withScreenMenu(
  List<MenuSubmenuEntry> model,
  ScreenMenuContribution? contribution,
) {
  if (contribution == null || contribution.entries.isEmpty) return model;
  final submenu = MenuSubmenuEntry(
    label: contribution.label,
    children: contribution.entries,
  );
  final windowIndex = model.indexWhere((m) => m.label == 'ウインドウ');
  if (windowIndex < 0) return [...model, submenu];
  return [...model.take(windowIndex), submenu, ...model.skip(windowIndex)];
}
