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

  /// ⚠⚠ **シート / ダイアログが開いている間も、コンテナを[借りている]
  /// [ProviderScopeLeases]ことにする**（リリース前レビュー・2026-10-10）。
  /// 数えていたのは push 先の画面だけで、ここは数えていなかった。別アカウント B の
  /// カラムからシートを開いたまま B 宛の通知をタップすると、B のコンテナが
  /// 破棄され、開いたままのシートが次の `ref.read` で StateError を投げる
  /// （#1235 と同じ筋）。
  @override
  Widget wrap(BuildContext context, Widget child) => _ProviderScopeLease(
    container: container,
    child: UncontrolledProviderScope(
      container: container,
      child: ProviderScopeCarrier(container: container, child: child),
    ),
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

/// `extra` に載せる開く側のスコープのキー。
const providerScopeExtraKey = '__providerScope';

/// 開く側のスコープを載せた `extra` を作る (#1149)。
///
/// ⚠⚠ **全画面のまま残る画面（投稿フォーム `/compose`・メディアビューア `/media`）
/// へ push するときは必ずこれを通す。**go_router のページの route は開く側の
/// スコープを持ち込まないので、何もしないと**カラム B から開いた返信フォームが
/// アカウント A として投稿する**。ルーター側は [withExtraProviderScope] で包む。
/// 素の `push('/compose' …)` は `provider_scope_push_guard_test` が落とす。
///
/// ⚠ `await` の後で呼ぶと `context` が使えないことがある。先に作っておくこと。
///
/// ⚠ ログイン状態が切り替わって go_router が `refreshListenable` で組み直すと、
/// JSON にできない `extra` は丸ごと null に落ちる（`router.dart` の
/// `loginLocation` の注記・#1057）。コンテナも落ちてルートのスコープに戻るが、
/// 同じ `extra` に載っている `Post` / `Attachment` も同時に落ちるので、この
/// 仕組みが新しく足した弱点ではない。
Map<String, dynamic> extraWithProviderScope(
  BuildContext context, [
  Map<String, dynamic>? extra,
]) => {
  ...?extra,
  providerScopeExtraKey: ProviderScope.containerOf(context, listen: false),
};

/// [container] を載せた `extra` を作る (#1170)。
///
/// ⚠⚠ **`context` からスコープを取れないときだけ使う。**ふつうは
/// [extraWithProviderScope] —— そちらは「開いた場所のスコープ」を自動で拾うので、
/// 取り違えようがない。
///
/// 要るのは**デスクトップメニューからの ⌘N** だけ。メニューバーは ShellRoute に
/// 常駐していて**ルートのスコープで動く**ので、そこの `context` から取ると
/// 「現在のアカウント」になってしまう。デッキ画面が自分の持っているカラムの
/// コンテナを渡す。
Map<String, dynamic> extraWithProviderContainer(
  ProviderContainer container, [
  Map<String, dynamic>? extra,
]) => {...?extra, providerScopeExtraKey: container};

/// `extra` に載っていたスコープで [child] を包む（ルーターの builder 用）。
/// 載っていなければそのまま（アプリ起動時の共有インテント等・ルートのスコープ）。
///
/// ⚠ 包んだ画面が生きている間、コンテナを[借りている][ProviderScopeLeases]
/// ことにする (#1235)。持ち主（デッキ画面）が先に手放しても、画面が閉じるまで
/// 破棄されない。
Widget withExtraProviderScope(Object? extra, Widget child) {
  final container = extra is Map ? extra[providerScopeExtraKey] : null;
  return container is ProviderContainer
      ? _ProviderScopeLease(
          container: container,
          child: carryProviderScope(container, child),
        )
      : child;
}

/// push 先の画面に貸しているコンテナの台帳 (#1235)。
///
/// ⚠⚠ **デッキ画面は、列に居なくなったアカウントのコンテナを破棄する。**数えて
/// いたのはカラムと簡易投稿バーだけで、**push 先（投稿フォーム・メディア
/// ビューア）に渡したぶんは数えていなかった**。別アカウント B のカラムから
/// 投稿フォームを開いたまま B 宛の通知をタップすると、アカウントが切り替わって
/// B のカラムがルートへ移り、B のコンテナは「未使用」として破棄される ——
/// スタックに残った投稿フォームが次の `ref.read` で StateError を投げる。
///
/// 持ち主は [disposeWhenReleased] で手放し、貸している間は破棄を先送りする。
abstract final class ProviderScopeLeases {
  static final Map<ProviderContainer, int> _counts = Map.identity();
  static final Set<ProviderContainer> _doomed = Set.identity();

  static bool isLeased(ProviderContainer container) =>
      (_counts[container] ?? 0) > 0;

  static void _acquire(ProviderContainer container) =>
      _counts[container] = (_counts[container] ?? 0) + 1;

  static void _release(ProviderContainer container) {
    final remaining = (_counts[container] ?? 0) - 1;
    if (remaining > 0) {
      _counts[container] = remaining;
      return;
    }
    _counts.remove(container);
    if (_doomed.remove(container)) container.dispose();
  }

  /// 持ち主が [container] を手放す。貸していなければその場で破棄し、貸して
  /// いれば最後の借り手が閉じたときに破棄する。
  static void disposeWhenReleased(ProviderContainer container) {
    if (isLeased(container)) {
      _doomed.add(container);
    } else {
      container.dispose();
    }
  }
}

class _ProviderScopeLease extends StatefulWidget {
  const _ProviderScopeLease({required this.container, required this.child});

  final ProviderContainer container;
  final Widget child;

  @override
  State<_ProviderScopeLease> createState() => _ProviderScopeLeaseState();
}

class _ProviderScopeLeaseState extends State<_ProviderScopeLease> {
  @override
  void initState() {
    super.initState();
    ProviderScopeLeases._acquire(widget.container);
  }

  @override
  void didUpdateWidget(_ProviderScopeLease oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.container, widget.container)) return;
    ProviderScopeLeases._acquire(widget.container);
    ProviderScopeLeases._release(oldWidget.container);
  }

  @override
  void dispose() {
    // ⚠ **破棄はフレームの後へ回す。**この画面の子がまだコンテナを読んでいる
    // 最中（同じフレームの unmount 中）に捨てると、子の dispose が投げる。
    final container = widget.container;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ProviderScopeLeases._release(container),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
