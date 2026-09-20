import 'package:flutter_riverpod/flutter_riverpod.dart';

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
