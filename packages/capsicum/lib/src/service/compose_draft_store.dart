import 'package:shared_preferences/shared_preferences.dart';

/// 入力中の投稿をローカルに自動保存する内容 (#966)。
///
/// **添付そのものは持たない。** ドライブ添付は id で戻せるが、ローカル添付は
/// ファイルパス依存で OS の一時領域が消えると失効する（トリミング結果やスタンプ
/// 合成後の一時ファイルも同様）。件数だけを持ち、復元時に「含まれていない」と
/// 伝えるために使う。
class ComposeDraft {
  final String text;
  final String cwText;
  final bool cwEnabled;
  final int attachmentCount;

  const ComposeDraft({
    required this.text,
    this.cwText = '',
    this.cwEnabled = false,
    this.attachmentCount = 0,
  });

  bool get hasText => text.isNotEmpty;
}

/// 投稿フォームのローカル自動保存の永続化 (#966)。
///
/// UI から切り離してあるのは、「破棄したあとは書き戻さない」という副作用の順序
/// が壊れやすく、テストで固定しておきたいため。保存範囲の拡張・アカウント別
/// スロットへの移行は #964 でここに載せる。
///
/// **インスタンスは 1 コンポーズ画面につき 1 つ**だが、保存スロット
/// （SharedPreferences）はプロセスで 1 枠しかない。デスクトップでは Ctrl+N /
/// メニューバーからコンポーズ画面を重ねて開けるため、別画面が [clear]（投稿・
/// サーバー下書き保存）したあとに古い画面が離脱時保存 (#966) を走らせると、
/// 消したはずの本文が書き戻って二重投稿の種になる (#969)。これを防ぐため、
/// スロットに世代印 ([generationKey]) を持たせ、**自分が最後に同期した世代と
/// スロットの現世代がズレていたら書き戻さない**。[clear] は世代を進めるので、
/// 別画面の [clear] は古い画面の [save] を自動的に無効化する。
class ComposeDraftStore {
  ComposeDraftStore();

  static const textKey = 'compose_draft_text';
  static const cwTextKey = 'compose_draft_cw_text';
  static const cwEnabledKey = 'compose_draft_cw_enabled';
  static const attachmentCountKey = 'compose_draft_attachment_count';

  /// スロットの世代印 (#969)。[clear] のたびに +1 する。各インスタンスは
  /// [restore] / [save] で見た世代を [_syncedGeneration] に覚え、[save] 時に
  /// 現世代とズレていたら（＝別画面が [clear] したあと）書き戻さない。
  static const generationKey = 'compose_draft_generation';

  bool _discarded = false;

  /// このインスタンスが最後にスロットと同期したときの世代 (#969)。まだ一度も
  /// [restore] / [save] していなければ null。
  int? _syncedGeneration;

  /// [clear] を通ったあとかどうか。
  bool get discarded => _discarded;

  /// 現在の入力を保存する。[clear] 済みなら何もしない。
  ///
  /// 投稿成功・サーバー下書き保存はどちらも [clear] の直後に画面を閉じるため、
  /// 離脱時の自動保存 (#966) がそのまま走ると**消したはずの本文が書き戻る**。
  /// 破棄済みを覚えて no-op にすることで、経路の順序に依存しなくなる。
  ///
  /// さらに、**別インスタンスが [clear] してスロットの世代が進んでいたら**書き
  /// 戻さない (#969)。重ねて開いた別画面が投稿したあと、こちらの古い本文で
  /// スロットを上書きして復活させてしまうのを防ぐ。
  Future<void> save(ComposeDraft draft) async {
    if (_discarded) return;
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt(generationKey) ?? 0;
    // 一度でも同期していて（restore/save 済み）、その後に別画面が clear で世代を
    // 進めていたら、こちらの書き戻しは stale なので捨てる。まだ同期していない
    // （null）場合は現世代を採用して通常どおり保存する。
    if (_syncedGeneration != null && _syncedGeneration != current) return;
    await prefs.setString(textKey, draft.text);
    await prefs.setString(cwTextKey, draft.cwText);
    await prefs.setBool(cwEnabledKey, draft.cwEnabled);
    await prefs.setInt(attachmentCountKey, draft.attachmentCount);
    _syncedGeneration = current;
  }

  /// 保存済みの入力を読む。何も保存されていなければ null。
  Future<ComposeDraft?> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _syncedGeneration = prefs.getInt(generationKey) ?? 0;
    final text = prefs.getString(textKey);
    final cwText = prefs.getString(cwTextKey);
    final cwEnabled = prefs.getBool(cwEnabledKey) ?? false;
    final attachmentCount = prefs.getInt(attachmentCountKey) ?? 0;
    if (text == null && cwText == null && !cwEnabled) return null;
    return ComposeDraft(
      text: text ?? '',
      cwText: cwText ?? '',
      cwEnabled: cwEnabled,
      attachmentCount: attachmentCount,
    );
  }

  /// 保存済みの入力を捨てる（投稿成功・サーバー下書き保存の後）。
  ///
  /// 世代を進めるので、重ねて開いている別画面の [save]（古い本文の書き戻し）が
  /// 以降無効になる (#969)。世代印そのものは残す。
  Future<void> clear() async {
    _discarded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(generationKey, (prefs.getInt(generationKey) ?? 0) + 1);
    await prefs.remove(textKey);
    await prefs.remove(cwTextKey);
    await prefs.remove(cwEnabledKey);
    await prefs.remove(attachmentCountKey);
  }
}
