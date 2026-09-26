import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/deck_column.dart';
import 'preferences_provider.dart';

/// 画面にあるデッキ画面の数 (#1099)。**0 なら閉じている。**
///
/// ⚠ bool でなく数で持つのは、閉じる / 開くが同じフレームに重なっても壊れない
/// ようにするため。`DeckScreen` は増減を**フレームの後**で行う（ライフサイクルの
/// 最中に provider を書き換えると Riverpod の assert に当たる）ので、`true` /
/// `false` の書き込みだと予約の順によっては「閉じた」が後から来て上書きしうる。
///
/// ⚠⚠ **「列にカラムがあるか」ではない。**`deckColumnsProvider` は永続化された
/// 構成なので、デッキを閉じていても中身は残る。カラムの TL provider が生きて
/// いるのは **デッキが開いている間だけ**（決定済み事項 5-3「列にあるカラムは
/// 全部生かす」は、裏を返せば閉じたら全部片づくということ）。
///
/// ⚠ 閉じているときに `readVisibleTimelines` がカラムを反映先に含めると、
/// **誰も watch していない autoDispose provider を `ref.read` で起こし、その
/// `build()` が REST を数ページ叩いて結果を誰にも使われないまま捨てる**
/// （`visible_timeline.dart` が `mainTimelineIsVisible` の doc で警告している穴と
/// 同じもの）。投稿・ブロックのたびにこれが走るので、フラグで切る。
///
/// 書き換えるのは `DeckScreen` の initState / dispose だけ。
final mountedDeckCountProvider = StateProvider<int>((ref) => 0);

/// この `ref` がデッキのカラムのスコープにあるか (#1099)。**ルートでは false**。
///
/// `DeckScreen` がカラムごとに作る `ProviderContainer` で上書きする。⚠ 上書き
/// するのは**現在のアカウント以外のカラム**だけ。現在のアカウントのカラムは
/// ルートのコンテナをそのまま使う（未決事項 10。別コンテナにすると HomeScreen と
/// 同じ購読キーでぶつかる）ので、そこでは false のままで正しい。
///
/// ⚠⚠ **用途は `selectedTabProvider` を読んでよいかの判定。**選択中タブは
/// アカウントに依存しない**単数**の状態なので、カラムのスコープで読むと
/// **ルートで選ばれているタブを、そのカラムのアカウントに当てた「誰も見ていない
/// TL」** を起こしてしまう（`visible_timeline.dart` の [readVisibleTimelines]）。
final inDeckColumnProvider = Provider<bool>((ref) => false);

/// フォーカス中のカラム (#1172・`docs/deck-ui-plan.md` 決定済み事項 10)。
///
/// ⚠ **「見えているカラム」でも「選択中のタブ」でもない。**デッキは複数アカウントの
/// カラムが並ぶので、**画面に 1 つしか置けないもの**（⌘N・簡易投稿バー・
/// `Ctrl+R` でのカラム更新・#1170 の「表示 > カラム」）が**どのカラムを宛先に
/// するか**を決めるための状態。
class DeckFocus {
  const DeckFocus({this.columnId, this.blinkToken = 0});

  /// フォーカス中のカラムの [DeckColumn.id]。列が空なら null。
  final String? columnId;

  /// 点滅の要求カウンタ。**増えたら 1 回点滅させる。**
  ///
  /// ⚠ フラグにすると「点滅した」を誰かが消さないと次が打てず、同じカラムを
  /// 続けて開いたときに 2 回目が鳴らない。⚠ **フォーカスの移動そのものでは
  /// 増やさない**（読むたびに枠が点滅すると目に障る）。
  final int blinkToken;

  @override
  bool operator ==(Object other) =>
      other is DeckFocus &&
      columnId == other.columnId &&
      blinkToken == other.blinkToken;

  @override
  int get hashCode => Object.hash(columnId, blinkToken);
}

/// [DeckFocus] の出し入れ。
///
/// ⚠⚠ **列の変化に追従する責務をここに閉じる。**カラムを閉じたときに隣へ移す・
/// 初期値を先頭にする、を画面側でやると「閉じた直後の 1 フレームだけ宛先が無い」
/// 状態が残り、その間に ⌘N が飛ぶと投稿先が決まらない。
final deckFocusProvider = NotifierProvider<DeckFocusNotifier, DeckFocus>(
  DeckFocusNotifier.new,
);

class DeckFocusNotifier extends Notifier<DeckFocus> {
  @override
  DeckFocus build() {
    // ⚠ `ref.watch` にしない。列が動くたびに notifier ごと作り直され、
    // フォーカスが毎回先頭へ戻る。
    ref.listen<List<DeckColumn>>(deckColumnsProvider, (previous, next) {
      _reconcile(previous ?? const [], next);
    });
    return DeckFocus(columnId: ref.read(deckColumnsProvider).firstOrNull?.id);
  }

  /// 列が変わったときにフォーカスを繋ぎ直す。**居るなら動かさない。**
  void _reconcile(List<DeckColumn> previous, List<DeckColumn> next) {
    if (next.isEmpty) {
      state = DeckFocus(blinkToken: state.blinkToken);
      return;
    }
    final id = state.columnId;
    if (id != null && next.any((c) => c.id == id)) return;
    // ⚠ 消えたカラムが居た位置をそのまま使うと、取り除いた後の列ではそこが
    // **右隣**になる（末尾だったときだけ clamp で左隣に落ちる）。
    final removedAt = previous.indexWhere((c) => c.id == id);
    final index = removedAt < 0 ? 0 : removedAt.clamp(0, next.length - 1);
    state = DeckFocus(columnId: next[index].id, blinkToken: state.blinkToken);
  }

  /// フォーカスを [id] へ移す。点滅はしない（カラムの中を押したときの経路）。
  void focus(String id) {
    if (state.columnId == id) return;
    state = DeckFocus(columnId: id, blinkToken: state.blinkToken);
  }

  /// フォーカスを [id] へ移し、**枠を 1 回点滅させる** (#1148 の出し先・
  /// 決定済み事項 10)。横送りで列がずれても、どこに出たかを見失わないため。
  ///
  /// ⚠ **既にフォーカス中でも点滅させる**（同じカラムから続けて開いた場合）。
  void focusAndBlink(String id) =>
      state = DeckFocus(columnId: id, blinkToken: state.blinkToken + 1);
}

/// カラムの再読み込みの登録口（カラム id → 再読み込み）(#1157 / #1170)。
///
/// ⚠⚠ **デスクトップにはカラムを取り直す手段が無かった。**トラックパッドの 2 本指
/// スクロールは `RefreshIndicator` を起動せず、見出しにも入口が無いので、
/// **カラムを閉じて足し直すしか方法が無かった**（#1098 の実機検証 B10）。
///
/// 中身（`_DeckTimelineBody` 等）が自分の再読み込みを登録し、メニューの
/// 「タイムラインを更新」/ `Ctrl+R` が**フォーカス中のカラム**のぶんを呼ぶ。
///
/// ⚠ 登録するのは**引っ張って更新と同じ経路**（`RefreshIndicator.show()`）。
/// provider を直接 refresh すると、スピナーの弧が出ず「効いていない」ように見える。
///
/// ⚠ 登録していないカラム（通知・検索など自前の取り直しを持つもの）では
/// null になる。メニュー側はそのとき項目を無効にする。
final deckColumnRefreshProvider =
    NotifierProvider<
      DeckColumnRefreshNotifier,
      Map<String, Future<void> Function()>
    >(DeckColumnRefreshNotifier.new);

class DeckColumnRefreshNotifier
    extends Notifier<Map<String, Future<void> Function()>> {
  @override
  Map<String, Future<void> Function()> build() => const {};

  /// [id] のカラムの再読み込みを登録する。
  ///
  /// ⚠⚠ **ウィジェットのライフサイクルの最中に呼ばない。**Riverpod は
  /// `initState` / `dispose` 中の書き換えを禁じている（`desktopTimelineRefreshProvider`
  /// の登録が post-frame になっているのと同じ理由）。呼ぶ側がフレームの外へ出す。
  void register(String id, Future<void> Function() refresh) =>
      state = {...state, id: refresh};

  /// [id] の登録を外す。⚠ **自分が登録したものだけを外す**（別のカラムが同じ id で
  /// 上書きしていたら触らない。列の入れ替えで作り直された直後がこれ）。
  void unregister(String id, Future<void> Function() refresh) {
    if (state[id] != refresh) return;
    state = {
      for (final e in state.entries)
        if (e.key != id) e.key: e.value,
    };
  }
}

/// デッキ画面だけが持っている操作を、デスクトップメニューへ渡す口 (#1170)。
///
/// ⚠⚠ **メニューはカラムのコンテナに手が届かない。**メニューバーは ShellRoute に
/// 常駐していてルートのスコープで動くので、そこから `/compose` を開くと
/// **現在のアカウント**として投稿される（#1149 と同じ穴）。デッキ画面が自分の
/// コンテナを使う閉じたものを登録し、メニューはそれを呼ぶだけにする。
class DeckMenuActions {
  const DeckMenuActions({
    required this.revealAndFocus,
    required this.openCompose,
    required this.openColumnsSheet,
  });

  /// そのカラムまで横に送り、フォーカスを移す（表示 > カラム）。
  final void Function(String columnId) revealAndFocus;

  /// フォーカス中のカラムのアカウントで新規投稿を開く（⌘N / Ctrl+N）。
  final VoidCallback openCompose;

  /// カラム編集のシートを開く（表示 > カラム > カラムを編集…）。
  final VoidCallback openColumnsSheet;
}

/// [DeckMenuActions] の登録口。**デッキ画面がマウント中だけ非 null**。
final deckMenuActionsProvider = StateProvider<DeckMenuActions?>((ref) => null);
