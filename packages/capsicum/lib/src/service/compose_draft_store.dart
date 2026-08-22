import 'package:capsicum_core/capsicum_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 入力中の投稿をローカルに自動保存する内容 (#966 / #964)。
///
/// **添付そのものは持たない。** ドライブ添付は id で戻せるが、ローカル添付は
/// ファイルパス依存で OS の一時領域が消えると失効する（トリミング結果やスタンプ
/// 合成後の一時ファイルも同様）。件数だけを持ち、復元時に「含まれていない」と
/// 伝えるために使う。アンケート・予約時刻も同じ理由で対象外 (#964)。
class ComposeDraft {
  final String text;
  final String cwText;
  final bool cwEnabled;
  final int attachmentCount;

  /// 公開範囲 (#964)。旧スロット（保存していなかった頃）から読んだときは null。
  final PostScope? scope;

  /// 閲覧注意 (#964)。CW とは独立したトグル（`_sensitiveEnabled`）。
  final bool sensitive;

  /// ローカルのみ (#964)。
  final bool localOnly;

  /// 最後に保存した時刻 (#964)。画面に「自動保存 12:34」として出す。
  /// 旧スロットから読んだときは null。
  final DateTime? savedAt;

  const ComposeDraft({
    required this.text,
    this.cwText = '',
    this.cwEnabled = false,
    this.attachmentCount = 0,
    this.scope,
    this.sensitive = false,
    this.localOnly = false,
    this.savedAt,
  });

  bool get hasText => text.isNotEmpty;
}

/// 投稿フォームのローカル自動保存の永続化 (#966 / #964)。
///
/// UI から切り離してあるのは、「破棄したあとは書き戻さない」という副作用の順序
/// が壊れやすく、テストで固定しておきたいため。
///
/// ## スロットはアカウント別 (#964)
///
/// 以前は `compose_draft_text` 等の**単一グローバルスロット**で、A アカウントで
/// 書きかけた本文が B アカウントの新規投稿画面に出てきていた。キーに
/// `AccountKey.toStorageKey()` を後置して分離する。[accountKey] が null（アカ
/// ウント未確定）のときは旧キーをそのまま使う。
///
/// 旧スロットに残っている入力は、**最初に読んだアカウントへ引き取る**
/// （[restore] 内で移行し、旧キーは消す）。捨てる選択肢もあったが、書きかけを
/// 黙って失うほうが害が大きい。
///
/// ## 世代印 (#969)
///
/// **インスタンスは 1 コンポーズ画面につき 1 つ**だが、同じアカウントのスロット
/// は共有される。デスクトップでは Ctrl+N / メニューバーからコンポーズ画面を
/// 重ねて開けるため、別画面が [clear]（投稿・サーバー下書き保存）したあとに
/// 古い画面が離脱時保存 (#966) を走らせると、消したはずの本文が書き戻って二重
/// 投稿の種になる。スロットに世代印を持たせ、**自分が最後に同期した世代と
/// スロットの現世代がズレていたら書き戻さない**。
class ComposeDraftStore {
  /// [accountKey] は `AccountKey.toStorageKey()`。null なら旧グローバルスロット。
  ComposeDraftStore({this.accountKey});

  /// スロットを分けるアカウント識別子 (#964)。
  final String? accountKey;

  static const textKey = 'compose_draft_text';
  static const cwTextKey = 'compose_draft_cw_text';
  static const cwEnabledKey = 'compose_draft_cw_enabled';
  static const attachmentCountKey = 'compose_draft_attachment_count';
  static const scopeKey = 'compose_draft_scope';
  static const sensitiveKey = 'compose_draft_sensitive';
  static const localOnlyKey = 'compose_draft_local_only';
  static const savedAtKey = 'compose_draft_saved_at';

  /// スロットの世代印 (#969)。[clear] のたびに +1 する。各インスタンスは
  /// [restore] / [save] で見た世代を [_syncedGeneration] に覚え、[save] 時に
  /// 現世代とズレていたら（＝別画面が [clear] したあと）書き戻さない。
  static const generationKey = 'compose_draft_generation';

  /// このスロットが使う全キー。アカウント別スロットの掃除 ([clearForAccount])
  /// と、旧スロットからの移行で使う。
  static const _allKeys = <String>[
    textKey,
    cwTextKey,
    cwEnabledKey,
    attachmentCountKey,
    scopeKey,
    sensitiveKey,
    localOnlyKey,
    savedAtKey,
  ];

  bool _discarded = false;
  int? _syncedGeneration;

  /// [clear] を通ったあとかどうか。
  bool get discarded => _discarded;

  String _k(String base) => accountKey == null ? base : '${base}_$accountKey';

  /// 現在の入力を保存する。[clear] 済みなら何もしない。
  ///
  /// 投稿成功・サーバー下書き保存はどちらも [clear] の直後に画面を閉じるため、
  /// 離脱時の自動保存 (#966) がそのまま走ると**消したはずの本文が書き戻る**。
  /// 破棄済みを覚えて no-op にすることで、経路の順序に依存しなくなる。
  ///
  /// さらに、**別インスタンスが [clear] してスロットの世代が進んでいたら**書き
  /// 戻さない (#969)。
  ///
  /// 保存した時刻を返す（画面の「自動保存 12:34」に使う）。no-op だった場合は
  /// null。⚠ **時刻は呼び出し側が渡す** — `DateTime.now()` を内部で呼ぶと
  /// テストで固定できない。
  Future<DateTime?> save(ComposeDraft draft, {required DateTime now}) async {
    if (_discarded) return null;
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt(_k(generationKey)) ?? 0;
    // 一度でも同期していて（restore/save 済み）、その後に別画面が clear で世代を
    // 進めていたら、こちらの書き戻しは stale なので捨てる。まだ同期していない
    // （null）場合は現世代を採用して通常どおり保存する。
    if (_syncedGeneration != null && _syncedGeneration != current) return null;
    await prefs.setString(_k(textKey), draft.text);
    await prefs.setString(_k(cwTextKey), draft.cwText);
    await prefs.setBool(_k(cwEnabledKey), draft.cwEnabled);
    await prefs.setInt(_k(attachmentCountKey), draft.attachmentCount);
    await prefs.setBool(_k(sensitiveKey), draft.sensitive);
    await prefs.setBool(_k(localOnlyKey), draft.localOnly);
    await prefs.setString(_k(savedAtKey), now.toIso8601String());
    if (draft.scope != null) {
      await prefs.setString(_k(scopeKey), draft.scope!.name);
    } else {
      await prefs.remove(_k(scopeKey));
    }
    _syncedGeneration = current;
    return now;
  }

  /// 保存済みの入力を読む。何も保存されていなければ null。
  ///
  /// アカウント別スロットが空で旧グローバルスロットに中身があれば、**このアカ
  /// ウントへ引き取る** (#964)。移行は 1 度きり（旧キーを消すため）。
  Future<ComposeDraft?> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _syncedGeneration = prefs.getInt(_k(generationKey)) ?? 0;

    var draft = _read(prefs, _k);
    if (draft == null && accountKey != null) {
      final legacy = _read(prefs, (k) => k);
      if (legacy != null) {
        await _removeAll(prefs, (k) => k);
        await save(legacy, now: legacy.savedAt ?? DateTime.now());
        draft = legacy;
      }
    }
    return draft;
  }

  ComposeDraft? _read(SharedPreferences prefs, String Function(String) key) {
    final text = prefs.getString(key(textKey));
    final cwText = prefs.getString(key(cwTextKey));
    final cwEnabled = prefs.getBool(key(cwEnabledKey)) ?? false;
    if (text == null && cwText == null && !cwEnabled) return null;
    final scopeName = prefs.getString(key(scopeKey));
    final savedAt = prefs.getString(key(savedAtKey));
    return ComposeDraft(
      text: text ?? '',
      cwText: cwText ?? '',
      cwEnabled: cwEnabled,
      attachmentCount: prefs.getInt(key(attachmentCountKey)) ?? 0,
      // 旧スロット由来や、未知の値（enum の増減）では null に落とす。落として
      // 困るのは既定値へ戻ることだけで、本文は失わない。
      scope: scopeName == null
          ? null
          : PostScope.values.where((s) => s.name == scopeName).firstOrNull,
      sensitive: prefs.getBool(key(sensitiveKey)) ?? false,
      localOnly: prefs.getBool(key(localOnlyKey)) ?? false,
      savedAt: savedAt == null ? null : DateTime.tryParse(savedAt),
    );
  }

  Future<void> _removeAll(
    SharedPreferences prefs,
    String Function(String) key,
  ) async {
    for (final base in _allKeys) {
      await prefs.remove(key(base));
    }
  }

  /// 保存済みの入力を捨てる（投稿成功・サーバー下書き保存の後）。
  ///
  /// 世代を進めるので、重ねて開いている別画面の [save]（古い本文の書き戻し）が
  /// 以降無効になる (#969)。世代印そのものは残す。
  ///
  /// [discard] は「**このインスタンスの以降の保存も止めるか**」。既定の true は
  /// 投稿成功・サーバー下書き保存向けで、どちらも直後に画面を閉じる。
  ///
  /// ⚠ **画面に留まったまま消す経路は false で呼ぶ (#1008)。**復元の「取消」が
  /// これで、true のままだと [discarded] を戻す手段が無く、`late final` の
  /// ストアを持つその画面の自動保存が**二度と効かない**（取消のあとに書いた
  /// 本文が黙って失われる）。
  Future<void> clear({bool discard = true}) async {
    if (discard) _discarded = true;
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getInt(_k(generationKey)) ?? 0) + 1;
    await prefs.setInt(_k(generationKey), next);
    // 世代を進めた当人なので、自分の印も進める。放っておくと世代ガード (#969)
    // が**自分自身の**以降の保存を stale と見て捨てる。
    if (!discard) _syncedGeneration = next;
    await _removeAll(prefs, _k);
  }

  /// アカウント削除時にそのスロットを掃除する (#964)。放っておくと孤児キーが
  /// 溜まり、同じ `@user@host` で入り直したときに他人の書きかけのように見える。
  ///
  /// ⚠ **世代印まで消す。**アカウントごと居なくなるので、残す意味がない。
  static Future<void> clearForAccount(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    for (final base in [..._allKeys, generationKey]) {
      await prefs.remove('${base}_$accountKey');
    }
  }
}
