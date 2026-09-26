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
