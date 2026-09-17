import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// カラムのスコープ（アカウント）を、そこから開いたシート / ダイアログ / メニューの
/// 中へ持ち込む (#1149)。
///
/// ⚠⚠ **BottomSheet / Dialog / PopupMenu は Navigator の下に積まれる**ので、
/// ウィジェット木の上ではカラムの `ProviderScope` の外に居る。何もしないと、
/// **カラム B から開いたアクションシートがアカウント A として動く**
/// （`deck_scope_spike_test` で実測・B-2 の本丸）。
///
/// これを `InheritedTheme` にしているのは、Flutter のそれらの route が
/// **開く側の `InheritedTheme` を `InheritedTheme.capture` で拾い、route の中身を
/// `wrap` で包み直す**から（`showModalBottomSheet` / `showDialog` / `showMenu` /
/// `DropdownButton`）。カラムの位置にこれを 1 つ置けば、**約 100 か所ある呼び出しを
/// 1 つも書き換えずに**、中身がカラムのアカウントで動く。
///
/// ⚠ **`context.push` の画面遷移はこの仕組みに乗らない**（ページの route は
/// capture しない）。全画面のまま残るもの（投稿フォーム・メディアビューア）は
/// `pushInScope` を通す。投稿・プロフィール等は新しいカラムとして開く（#1148）。
class ProviderScopeCarrier extends InheritedTheme {
  const ProviderScopeCarrier({
    super.key,
    required this.container,
    required super.child,
  });

  final ProviderContainer container;

  @override
  Widget wrap(BuildContext context, Widget child) => UncontrolledProviderScope(
    container: container,
    child: ProviderScopeCarrier(container: container, child: child),
  );

  @override
  bool updateShouldNotify(ProviderScopeCarrier oldWidget) =>
      !identical(container, oldWidget.container);
}

/// [container] のスコープで [child] を描き、そこから開くシート等にも持ち込む。
Widget carryProviderScope(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: ProviderScopeCarrier(container: container, child: child),
    );
