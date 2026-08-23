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

/// 下書きの書き込みが拒まれた (#1011)。
///
/// `SharedPreferences` の setter は失敗しても投げず false を返すので、ここで
/// 例外へ翻訳する。**意図的な no-op（破棄済み・世代ズレ）と同じ null にしない**
/// ため — 呼び出し側が区別できないと、失敗が観測も通知もされないまま古い保存
/// 時刻が表示に残る（Codex P2 / PR #1013）。
///
/// ⚠ **メッセージに本文を載せない。** Sentry へ出る。
class ComposeDraftSaveException implements Exception {
  const ComposeDraftSaveException(this.message);

  final String message;

  @override
  String toString() => 'ComposeDraftSaveException: $message';
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
///
/// ⚠⚠ **その代償として、古い画面の「まだ保存していない入力」も捨てる** (#976)。
///
/// A で書きかけ → B で投稿 → A を閉じる、という並びだと、A の書きかけは保存
/// されずに消える。A が最後に自動保存できたところまでは残るが、そのあとの打鍵
/// は失われる。**「消したはずの本文が復活する」と「書きかけが保存されない」の
/// どちらを取るか**という話で、前者は二重投稿につながるのでこちらを選んでいる。
///
/// これは**スロットがプロセスに 1 枠しか無いことの必然**で、世代印の実装を
/// 変えても解けない。解消するなら「画面ごとに独立したスロットを持つ」— つまり
/// #964 のアカウント別スロットをさらに画面別へ広げる筋になる。
///
/// ⚠ **捨てたことを画面が黙っていないか気にすること。**[save] は世代ガードで
/// 弾いたとき null を返すだけなので、呼び出し側がそれを無視すると
/// 「自動保存 hh:mm」を出したまま固まる（#1012 で扱っている）。
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
  bool _superseded = false;

  /// [clear] を通ったあとかどうか。
  bool get discarded => _discarded;

  /// **別のインスタンスがこのスロットを [clear] した**あとかどうか (#1012)。
  ///
  /// [save] の世代ガードが弾いたら true になる。
  ///
  /// ⚠ **恒久ではない (v1.60 レビュー)。**初版の doc は「ズレは恒久」と書いて
  /// いたが、この画面自身の「取消」(`clear(discard: false)`) は世代を進めて
  /// **自分の印も合わせる**ので、そこから保存は復活する。latch したままにすると
  /// **保存できているのに「自動保存は停止中」を出し続ける**という、#1012 が
  /// 直そうとした食い違いの逆向きが残る。[save] が書き戻せたら false へ戻す。
  ///
  /// ⚠ **[discarded] と混ぜない。**どちらも [save] が null を返すが、意味が
  /// 正反対:
  ///
  /// - [discarded] — **この画面が**投稿 / サーバー下書き保存を終えた。直後に
  ///   画面が閉じるので、保存されないことに実害は無い
  /// - [superseded] — **別の画面が**片づけた。こちらの画面はまだ開いていて、
  ///   ユーザーは書き続けられる。**なのに保存されない**
  ///
  /// 呼び出し側はこれを見て「自動保存 hh:mm」を下ろすこと。残すと、**書けて
  /// いないのに最後に成功した時刻が出たまま固まる**（#964 の主目的が
  /// 「保存タイミングの可視化」である以上、表示が実態と食い違うと効果が反転
  /// する）。#1011 が書き込み拒否で同じ判断をしたのと同型。
  bool get superseded => _superseded;

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
  /// 保存した時刻を返す（画面の「自動保存 12:34」に使う）。**意図的な no-op**
  /// （破棄済み・世代ズレ）では null。⚠ **時刻は呼び出し側が渡す** —
  /// `DateTime.now()` を内部で呼ぶとテストで固定できない。
  ///
  /// ⚠ **書き込みが拒まれたら [ComposeDraftSaveException] を投げる (#1011)。**
  /// null と混ぜると、呼び出し側が「意図した no-op」と区別できず、失敗が観測も
  /// 通知もされないまま**古い保存時刻が表示に残る**（Codex P2 / PR #1013）。
  Future<DateTime?> save(ComposeDraft draft, {required DateTime now}) async {
    if (_discarded) return null;
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt(_k(generationKey)) ?? 0;
    // 一度でも同期していて（restore/save 済み）、その後に別画面が clear で世代を
    // 進めていたら、こちらの書き戻しは stale なので捨てる。まだ同期していない
    // （null）場合は現世代を採用して通常どおり保存する。
    if (_syncedGeneration != null && _syncedGeneration != current) {
      // ⚠ **恒久的にズレたことを覚える (#1012)。**`_syncedGeneration` を現世代へ
      // 進めない設計なので、一度ここへ来た画面は二度と保存できない。黙って
      // null を返すだけだと、呼び出し側は「保存できた最後の時刻」を出したまま
      // 固まる。
      _superseded = true;
      return null;
    }
    // ⚠ **書けたかどうかを見る (#1011)。**`setString` 等は失敗しても throw せず
    // false を返す。捨てていたため、**書けていないのに画面へ「自動保存 12:34」**
    // が出ていた。ユーザーはそれを信じてアプリを終了し、本文を失う。
    // 拒否は下で例外へ翻訳する（意図的な no-op と同じ null にしない）。
    var ok = true;
    ok = await prefs.setString(_k(textKey), draft.text) && ok;
    ok = await prefs.setString(_k(cwTextKey), draft.cwText) && ok;
    ok = await prefs.setBool(_k(cwEnabledKey), draft.cwEnabled) && ok;
    ok =
        await prefs.setInt(_k(attachmentCountKey), draft.attachmentCount) && ok;
    ok = await prefs.setBool(_k(sensitiveKey), draft.sensitive) && ok;
    ok = await prefs.setBool(_k(localOnlyKey), draft.localOnly) && ok;
    ok = await prefs.setString(_k(savedAtKey), now.toIso8601String()) && ok;
    if (draft.scope != null) {
      ok = await prefs.setString(_k(scopeKey), draft.scope!.name) && ok;
    } else {
      await prefs.remove(_k(scopeKey));
    }
    // 世代印は書き込みの成否と別（このスロットに触った事実は変わらない）。
    //
    // ⚠⚠ **await をまたいだ間に [clear] が進めた印を巻き戻さない (v1.60 レビュー)。**
    // 上の 8 回の書き込みは platform channel 往復なので、その最中に同じ画面の
    // 「取消」(`clear(discard: false)`) が走ると、あちらは `_syncedGeneration`
    // を N+1 へ進める。ここで無条件に `current`(= N) を代入すると印が巻き戻り、
    // **以降の save が毎回「世代ズレ」で捨てられて、その画面の自動保存が恒久的に
    // 死ぬ**（#1008 が塞いだ「取消のあとの本文が黙って消える」が別経路で戻る）。
    final synced = _syncedGeneration;
    if (synced != null && synced > current) {
      // ⚠⚠ **巻き戻さないだけでは足りない (Codex P2 / PR #1023)。**上の 8 回の
      // 書き込みと `clear` の削除は**互いに割り込む**ので、こちらの値が削除の
      // 後に着地しうる。印だけ守って抜けると:
      //
      // - **取消したはずの本文がスロットに残り**、次の restore で戻ってくる
      // - `now` を返すので、画面が消えたデータに対して「自動保存 12:34」を出す
      //
      // 書いたものを片づけて no-op として返す。`_allKeys` に世代印は含まれない
      // ので、取消が進めた世代はそのまま残る（この画面の以降の保存は効く）。
      await _removeAll(prefs, _k);
      return null;
    }
    _syncedGeneration = current;
    // 書き戻せた＝この画面はまだ現役。停止表示を解く（下の [superseded] 参照）。
    _superseded = false;
    if (!ok) {
      throw const ComposeDraftSaveException(
        'shared preferences rejected write',
      );
    }
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
  /// 完全に永続化できたかを返す。false は「拒まれた書き込みがある」＝ **次の
  /// 起動で消したはずの本文が戻りうる**という意味 (Codex P2 / PR #1013)。
  /// 呼び出し側は観測に残す。投げないのは、投稿成功の直後にも通る経路で、
  /// ここで投げると**投稿は通っているのに失敗と伝える**ことになるため。
  Future<bool> clear({bool discard = true}) async {
    if (discard) _discarded = true;
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getInt(_k(generationKey)) ?? 0) + 1;
    final advanced = await prefs.setInt(_k(generationKey), next);
    // 世代を進めた当人なので、自分の印も進める。放っておくと世代ガード (#969)
    // が**自分自身の**以降の保存を stale と見て捨てる。
    //
    // ⚠ **書き込みが拒まれても進める。**`SharedPreferences` は setter の結果に
    // 関わらず**プロセス内のキャッシュを先に更新する**（`_setValue` は
    // `_preferenceCache[key] = value` してからストアを呼ぶ）ので、拒否されても
    // このプロセスの `getInt` は新しい世代を返す。ここで印を据え置くと、以降の
    // [save] が毎回「世代ズレ」の no-op になり、**取消のあとの本文が黙って
    // 保存されない**（#1008 と同じ症状が別経路で戻る）。永続化の失敗は戻り値で
    // 伝える。
    if (!discard) _syncedGeneration = next;
    var removed = true;
    for (final base in _allKeys) {
      removed = await prefs.remove(_k(base)) && removed;
    }
    return advanced && removed;
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
