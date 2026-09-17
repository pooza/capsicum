import 'package:capsicum_core/capsicum_core.dart';

import 'account_key.dart';

/// デッキのカラム 1 本 (#1091)。カラム列はこれの順序つきリスト。
///
/// ⚠⚠ **「列の要素」と「中身」を分けて識別する**（`docs/deck-ui-plan.md`
/// 決定済み事項 6-2）。カラムは**重複できる**（同じアカウントの同じタグを 2 本
/// 置いてよい）ので、中身だけでは並べ替え・削除の対象を指せない。
///
/// | | 何で識別するか |
/// | --- | --- |
/// | 列の要素（並べ替え・削除・Widget の key） | [id]（追加時に採番。⚠ index を使わない） |
/// | 中身（provider の family キー） | [account] + [tab]。重複カラムは同じインスタンスを共有する |
class DeckColumn {
  const DeckColumn({
    required this.id,
    required this.account,
    required this.tab,
  });

  /// 列内の安定 ID。並べ替えても変わらない。
  final String id;

  /// このカラムのアカウント。⚠ フェーズ 1 では全カラム同じだが、**最初から
  /// 保存形式に含める**（フェーズ 2 で書式を変えなくて済むように）。
  final AccountKey account;

  /// このカラムに出すもの。⚠ **ラベル（リスト名等）は実行時に解決する。**
  /// 保存は [TabType.toIdentityKey] で行うので、読み戻した [ListTab] /
  /// [ChannelTab] の `name` は null。
  final TabType tab;

  /// 中身の同一性を表す文字列。`timelineContextKey` と同じ
  /// `<アカウント>|<種別>` の形（決定済み事項 4-3）。
  String get contentKey => '${account.toStorageKey()}|${tab.toIdentityKey()}';

  /// 保存用の 1 行。`<id>|<アカウント>|<種別>`。
  ///
  /// ⚠ 種別は [TabType.toKey] ではなく [TabType.toIdentityKey]。[toKey] は表示名を
  /// 含むので、サーバー側でリスト名を変えると同じカラムが別物になる（4-1）。
  String serialize() => '$id|${account.toStorageKey()}|${tab.toIdentityKey()}';

  /// [serialize] の逆。**読めない行は null**（落とさない・既定へ倒すのは呼ぶ側）。
  ///
  /// 読めないのは: 区切りが足りない / id が空 / アカウントの書式が壊れている・
  /// 未知のバックエンド / 未知の種別（新しい版で足した種別を古い版が読んだ場合を
  /// 含む。[TabType.fromKey] と同じ forward-compatible な方針）。
  static DeckColumn? deserialize(String line) {
    final first = line.indexOf('|');
    if (first <= 0) return null;
    final second = line.indexOf('|', first + 1);
    if (second < 0) return null;

    final id = line.substring(0, first);
    // 種別側に `|` が入っても壊れないよう、3 つ目以降はまとめて種別として読む。
    final tab = TabType.fromKey(line.substring(second + 1));
    if (tab == null) return null;

    final AccountKey account;
    try {
      account = AccountKey.fromStorageKey(line.substring(first + 1, second));
    } catch (_) {
      // 未知のスキーム（firstWhere の StateError）や壊れた URI（FormatException）。
      return null;
    }
    if (account.host.isEmpty || account.username.isEmpty) return null;

    return DeckColumn(id: id, account: account, tab: tab);
  }
}
