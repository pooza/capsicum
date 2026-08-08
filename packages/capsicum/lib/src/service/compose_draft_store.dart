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
class ComposeDraftStore {
  ComposeDraftStore();

  static const textKey = 'compose_draft_text';
  static const cwTextKey = 'compose_draft_cw_text';
  static const cwEnabledKey = 'compose_draft_cw_enabled';
  static const attachmentCountKey = 'compose_draft_attachment_count';

  bool _discarded = false;

  /// [clear] を通ったあとかどうか。
  bool get discarded => _discarded;

  /// 現在の入力を保存する。[clear] 済みなら何もしない。
  ///
  /// 投稿成功・サーバー下書き保存はどちらも [clear] の直後に画面を閉じるため、
  /// 離脱時の自動保存 (#966) がそのまま走ると**消したはずの本文が書き戻る**。
  /// 破棄済みを覚えて no-op にすることで、経路の順序に依存しなくなる。
  Future<void> save(ComposeDraft draft) async {
    if (_discarded) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(textKey, draft.text);
    await prefs.setString(cwTextKey, draft.cwText);
    await prefs.setBool(cwEnabledKey, draft.cwEnabled);
    await prefs.setInt(attachmentCountKey, draft.attachmentCount);
  }

  /// 保存済みの入力を読む。何も保存されていなければ null。
  Future<ComposeDraft?> restore() async {
    final prefs = await SharedPreferences.getInstance();
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
  Future<void> clear() async {
    _discarded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(textKey);
    await prefs.remove(cwTextKey);
    await prefs.remove(cwEnabledKey);
    await prefs.remove(attachmentCountKey);
  }
}
