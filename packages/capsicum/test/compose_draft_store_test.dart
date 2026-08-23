import 'package:capsicum/src/service/compose_draft_store.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// 世代印の書き込みだけを拒む prefs (Codex P2 / PR #1013)。スロットの世代が
/// 据え置かれるのに、インスタンス側の印だけ進むと何が起きるかを見る。
class _GenerationRejectingStore extends InMemorySharedPreferencesStore {
  _GenerationRejectingStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.contains(ComposeDraftStore.generationKey)) return false;
    return super.setValue(valueType, key, value);
  }
}

/// 書き込みを拒む prefs (#1011)。`SharedPreferences` の setter は失敗しても
/// 投げず **false を返す**ので、この形でしか再現できない（端末が容量いっぱい・
/// ストレージが壊れている・プラグイン側が落ちている、等）。
class _RejectingStore extends InMemorySharedPreferencesStore {
  _RejectingStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    // 世代印だけは通す（clear の副作用まで潰すと検査の意図がぼやける）。
    if (key.contains(ComposeDraftStore.generationKey)) {
      return super.setValue(valueType, key, value);
    }
    return false;
  }
}

/// #966: 投稿フォームのローカル自動保存。保存範囲の拡張とアカウント別スロットは
/// #964 で足した（[ComposeDraftStore.accountKey]）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 保存時刻は呼び出し側が渡す (#964)。内部で `DateTime.now()` を呼ぶと
  /// 固定できないため。ここでは中身を見ない検査が多いので定数で足りる。
  final fixedNow = DateTime.utc(2026, 8, 22, 12, 34);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ComposeDraftStore (#966)', () {
    test('保存した内容をそのまま読み戻す', () async {
      await ComposeDraftStore().save(
        const ComposeDraft(
          text: '今日の実況の準備を',
          cwText: 'ネタバレ',
          cwEnabled: true,
          attachmentCount: 2,
        ),
        now: fixedNow,
      );

      final restored = await ComposeDraftStore().restore();
      expect(restored, isNotNull);
      expect(restored!.text, '今日の実況の準備を');
      expect(restored.cwText, 'ネタバレ');
      expect(restored.cwEnabled, isTrue);
      expect(restored.attachmentCount, 2);
    });

    test('何も保存していなければ null', () async {
      expect(await ComposeDraftStore().restore(), isNull);
    });

    test('REGRESSION: clear のあとの save は書き戻さない', () async {
      // 投稿成功・サーバー下書き保存はどちらも clear の直後に画面を閉じる。
      // 離脱時の自動保存 (#966) がそのまま走ると、消したはずの本文が復活して
      // 次に投稿画面を開いたときに再出現する。
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '投稿した本文'), now: fixedNow);
      await store.clear();

      await store.save(const ComposeDraft(text: '投稿した本文'), now: fixedNow);

      expect(store.discarded, isTrue);
      expect(await ComposeDraftStore().restore(), isNull);
    });

    test('clear は添付件数も消す（次の復元で古い注記を出さない）', () async {
      final store = ComposeDraftStore();
      await store.save(
        const ComposeDraft(text: '本文', attachmentCount: 3),
        now: fixedNow,
      );
      await store.clear();

      final next = ComposeDraftStore();
      await next.save(const ComposeDraft(text: '次の本文'), now: fixedNow);

      final restored = await next.restore();
      expect(restored!.text, '次の本文');
      expect(restored.attachmentCount, 0);
    });

    test('添付ゼロで保存すれば件数もゼロ', () async {
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '本文'), now: fixedNow);
      expect((await store.restore())!.attachmentCount, 0);
    });

    test('本文が空でも CW だけ生きていれば復元対象', () async {
      final store = ComposeDraftStore();
      await store.save(
        const ComposeDraft(text: '', cwEnabled: true),
        now: fixedNow,
      );

      final restored = await store.restore();
      expect(restored, isNotNull);
      expect(restored!.hasText, isFalse);
      expect(restored.cwEnabled, isTrue);
    });

    test('REGRESSION(#969): 別画面が clear したら古い画面の save は書き戻さない', () async {
      // デスクトップで Ctrl+N / メニューバーからコンポーズを重ねて開くと、
      // 保存スロットは 1 枠なのに画面（インスタンス）は 2 つになる。片方が
      // 投稿して clear したあと、もう片方が離脱時保存 (#966) を走らせると、
      // 消したはずの本文が復活して二重投稿の種になる。
      await ComposeDraftStore().save(
        const ComposeDraft(text: 'hello'),
        now: fixedNow,
      );

      // 画面 A / B とも同じ下書きを復元。
      final a = ComposeDraftStore();
      final b = ComposeDraftStore();
      expect((await a.restore())!.text, 'hello');
      expect((await b.restore())!.text, 'hello');

      // B が投稿 → clear。A は破棄済みではない（別インスタンス）。
      await b.clear();

      // A が離脱 → 保存を試みるが、世代が進んでいるので書き戻さない。
      await a.save(const ComposeDraft(text: 'hello'), now: fixedNow);

      expect(await ComposeDraftStore().restore(), isNull);
    });

    /// #1012: 世代ガードで弾かれたことを、呼び出し側が**知れる**こと。
    ///
    /// ⚠ **`_syncedGeneration` を進めない設計なので、ズレは恒久。**黙って null
    /// を返すだけだと、画面は「自動保存 12:34」を出したまま固まり、その後に
    /// 書いた本文まで保存されているように読める（#964 の主目的が保存タイミング
    /// の可視化である以上、表示が実態と食い違うと効果が反転する）。
    test('#1012: 別画面に片づけられたら superseded が立つ', () async {
      await ComposeDraftStore().save(
        const ComposeDraft(text: 'hello'),
        now: fixedNow,
      );

      final a = ComposeDraftStore();
      final b = ComposeDraftStore();
      await a.restore();
      await b.restore();
      expect(a.superseded, isFalse, reason: 'まだ誰も片づけていない');

      await b.clear();
      expect(
        await a.save(const ComposeDraft(text: 'hello'), now: fixedNow),
        isNull,
      );

      expect(a.superseded, isTrue);
      expect(a.discarded, isFalse, reason: 'discarded は「この画面が投稿し終えた」で、意味が正反対');
      // 弾かれ続ける限り立ったままであることを見る。ここが false に戻ると
      // 「1 回だけ表示を下ろしてまた嘘の時刻に戻る」というより悪い挙動になる。
      // ⚠ **下りる条件は「保存が通ったとき」だけ**（v1.60 レビュー）。この画面
      // 自身の取消で復活する経路は下の REGRESSION が見る。
      expect(
        await a.save(const ComposeDraft(text: 'hello'), now: fixedNow),
        isNull,
      );
      expect(a.superseded, isTrue);
    });

    test('#1012: 自分で clear した画面は superseded にしない', () async {
      final store = ComposeDraftStore();
      await store.restore();
      await store.clear();

      expect(
        await store.save(const ComposeDraft(text: 'x'), now: fixedNow),
        isNull,
      );
      expect(store.superseded, isFalse, reason: '投稿直後は画面が閉じるので、停止を知らせる相手が居ない');
      expect(store.discarded, isTrue);
    });

    test('#969: clear 後に新しい画面が restore→save すれば自動保存は復活する', () async {
      await ComposeDraftStore().save(
        const ComposeDraft(text: '投稿した本文'),
        now: fixedNow,
      );

      final posted = ComposeDraftStore();
      await posted.restore();
      await posted.clear();

      // clear 後に開いた新しい画面。復元は空だが、以降の保存は効く。
      final fresh = ComposeDraftStore();
      expect(await fresh.restore(), isNull);
      await fresh.save(const ComposeDraft(text: '新しい下書き'), now: fixedNow);

      expect((await ComposeDraftStore().restore())!.text, '新しい下書き');
    });

    test('#969: restore を挟まない単発 save は従来どおり書ける（世代ガードで塞がない）', () async {
      // 世代を一度進めておく（別画面の投稿相当）。
      final prior = ComposeDraftStore();
      await prior.save(const ComposeDraft(text: '前の本文'), now: fixedNow);
      await prior.clear();

      // restore を通らないインスタンスは基準世代 null なので、現世代を採用して
      // 通常どおり保存できる（standalone 契約を壊さない）。
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '単発保存'), now: fixedNow);

      expect((await ComposeDraftStore().restore())!.text, '単発保存');
    });

    /// #1011 (Codex P2 / PR #1013): 書き込みの拒否を、意図的な no-op と同じ
    /// null で返してはいけない。区別できないと呼び出し側が失敗を観測も通知も
    /// できず、**古い「自動保存 12:34」が表示に残ったまま本文を失う**。
    test('REGRESSION: 書き込みを拒まれたら投げる（no-op の null と混ぜない）', () async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = _RejectingStore();

      final store = ComposeDraftStore();

      await expectLater(
        store.save(const ComposeDraft(text: '書けない本文'), now: fixedNow),
        throwsA(isA<ComposeDraftSaveException>()),
      );
      // 破棄印は立てない（次の打鍵で再挑戦できる）。
      expect(store.discarded, isFalse);
    });

    /// Codex P2 (PR #1013): 世代印の永続化が拒まれた取消。
    ///
    /// ⚠ **「書けたときだけ印を進める」ではこの検査が落ちる。** `SharedPreferences`
    /// は setter の結果に関わらずプロセス内のキャッシュを先に更新するので、拒否
    /// されてもこのプロセスの `getInt` は新しい世代を返す。印を据え置くと以降の
    /// [ComposeDraftStore.save] が毎回「世代ズレ」の no-op になり、**#1008 と
    /// 同じ症状が別経路で戻る**（しかも no-op なので失敗としても出ない）。
    /// 永続化の失敗は [ComposeDraftStore.clear] の戻り値で伝える。
    test('REGRESSION: 世代を書けなかった取消でも、以降の保存は効く', () async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = _GenerationRejectingStore();

      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '前回の書きかけ'), now: fixedNow);
      await store.restore();

      expect(
        await store.clear(discard: false),
        isFalse,
        reason: '永続化できなかったことは戻り値で伝える',
      );

      expect(
        await store.save(
          const ComposeDraft(text: '取消のあとに書いた本文'),
          now: fixedNow,
        ),
        fixedNow,
      );
      expect((await ComposeDraftStore().restore())!.text, '取消のあとに書いた本文');
    });

    test('書き込みが通る環境では clear は true を返す', () async {
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '本文'), now: fixedNow);

      expect(await store.clear(), isTrue);
    });

    /// v1.60 リリース前レビュー: **in-flight の `save` が、取消の進めた世代印を
    /// 巻き戻す**。
    ///
    /// `save` の書き込みは 8 回の platform channel 往復で、その最中に同じ画面の
    /// 「取消」が走りうる（デバウンス発火後はタイマー cancel が効かない）。
    /// `save` が最後に無条件で古い世代を代入すると、以降の保存が毎回「世代ズレ」
    /// で捨てられ、**その画面の自動保存が恒久的に死ぬ**。#1008 が塞いだ症状が
    /// また別経路で戻る形。
    test('REGRESSION: 取消と競合した保存は、世代印を巻き戻さない', () async {
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '前回の書きかけ'), now: fixedNow);
      await store.restore();

      // save を待たずに取消を差し込む（await しないので、直列化が無ければ
      // 両者が同時に進む）。
      final saving = store.save(
        const ComposeDraft(text: '保存中の本文'),
        now: fixedNow,
      );
      final clearing = store.clear(discard: false);
      await Future.wait([saving, clearing]);

      // ⚠⚠ **storage を見るのは、次の save で上書きする前 (Codex P2 / PR #1023)。**
      // 初版はここで先に「取消のあとに書いた本文」を保存してから中身を見ており、
      // **競合で残った本文が上書きされて観測できなかった**。印の巻き戻りだけを
      // 見て、データの復活を見逃す形になっていた。
      expect(
        await ComposeDraftStore().restore(),
        isNull,
        reason: '取消したのに、競合した save の本文がスロットへ残ってはいけない',
      );

      // 印が巻き戻っていないので、取消のあとの入力はふつうに保存できる。
      expect(
        await store.save(
          const ComposeDraft(text: '取消のあとに書いた本文'),
          now: fixedNow,
        ),
        fixedNow,
        reason: '印が巻き戻っていると、ここが no-op の null になる',
      );
      expect(store.superseded, isFalse);
      expect((await ComposeDraftStore().restore())!.text, '取消のあとに書いた本文');
    });

    /// v1.60 リリース PR の Codex P2: **追い越された save が、新しい save の
    /// 本文を道連れにする**。
    ///
    /// 「割り込みを検出して自分の書き込みを片づける」形（#1023 の初版）だと、
    /// 片づけの時点で**もっと新しい save が着地している**ことがある。スロットは
    /// 1 枠なので一括削除がそれごと消し、画面は新しい保存の「自動保存 hh:mm」を
    /// 出したまま、再起動すると何も戻らない。
    ///
    /// 検出して直すのではなく、[ComposeDraftStore] の中で直列化して**重ならない
    /// ようにする**。
    test('REGRESSION: 取消のあとに保存した本文を、古い save が消さない', () async {
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '前回の書きかけ'), now: fixedNow);
      await store.restore();

      // 3 つとも await せずに積む。直列化が無いと 1 番目が 3 番目を消す。
      final stale = store.save(
        const ComposeDraft(text: '取消される前の本文'),
        now: fixedNow,
      );
      final cancelling = store.clear(discard: false);
      final fresh = store.save(
        const ComposeDraft(text: '取消のあとに書き直した本文'),
        now: fixedNow,
      );
      await Future.wait([stale, cancelling, fresh]);

      expect(
        (await ComposeDraftStore().restore())?.text,
        '取消のあとに書き直した本文',
        reason: '古い save の後始末が、新しい save の本文まで消してはいけない',
      );
      expect(await fresh, fixedNow, reason: '画面に出す時刻と中身が食い違ってはいけない');
      expect(store.superseded, isFalse);
    });

    /// v1.60 リリース前レビュー: `superseded` は **latch しない**。
    ///
    /// 初版の doc は「ズレは恒久」と書いていたが、その画面自身の取消は世代を
    /// 進めて印も合わせるので保存は復活する。latch したままだと、画面は
    /// **保存できているのに「自動保存は停止中」を出し続ける**。
    test('REGRESSION: 取消で保存が復活したら superseded は下りる', () async {
      await ComposeDraftStore().save(
        const ComposeDraft(text: '前回の書きかけ'),
        now: fixedNow,
      );
      final screen = ComposeDraftStore();
      await screen.restore();

      // 別画面が片づけて世代が進む → この画面は停止状態になる。
      await ComposeDraftStore().clear();
      expect(
        await screen.save(const ComposeDraft(text: 'x'), now: fixedNow),
        isNull,
      );
      expect(screen.superseded, isTrue);

      // 自分の取消で世代を進め直すと保存は効く。表示も戻さないと嘘になる。
      await screen.clear(discard: false);

      expect(
        await screen.save(const ComposeDraft(text: '復活後の本文'), now: fixedNow),
        fixedNow,
      );
      expect(screen.superseded, isFalse);
    });

    /// #1008: 復元の「取消」だけは画面に留まったまま消す。破棄済みにすると、
    /// `late final` のストアを持つその画面の自動保存が二度と効かず、取消の
    /// あとに書いた本文が黙って失われる。
    test('REGRESSION: clear(discard: false) のあとも、その画面の保存は効く', () async {
      await ComposeDraftStore().save(
        const ComposeDraft(text: '前回の書きかけ'),
        now: fixedNow,
      );

      // 画面が開いて復元 → 「取消」。
      final screen = ComposeDraftStore();
      expect((await screen.restore())!.text, '前回の書きかけ');
      await screen.clear(discard: false);

      expect(screen.discarded, isFalse);
      expect(await ComposeDraftStore().restore(), isNull);

      // 取消のあとに書いた本文は、同じインスタンスから保存できる。
      final savedAt = await screen.save(
        const ComposeDraft(text: '取消のあとに書いた本文'),
        now: fixedNow,
      );

      expect(savedAt, fixedNow);
      expect((await ComposeDraftStore().restore())!.text, '取消のあとに書いた本文');
    });

    test('#1008: 取消でも世代は進む（別画面の古い書き戻しは止めたまま）', () async {
      await ComposeDraftStore().save(
        const ComposeDraft(text: '共有の下書き'),
        now: fixedNow,
      );

      final a = ComposeDraftStore();
      final b = ComposeDraftStore();
      expect((await a.restore())!.text, '共有の下書き');
      expect((await b.restore())!.text, '共有の下書き');

      // B が取消（画面は開いたまま）。
      await b.clear(discard: false);

      // A の離脱時保存は stale なので書き戻さない (#969)。
      expect(
        await a.save(const ComposeDraft(text: '共有の下書き'), now: fixedNow),
        isNull,
      );
      expect(await ComposeDraftStore().restore(), isNull);
    });
  });

  group('保存範囲の拡張 (#964)', () {
    test('公開範囲・閲覧注意・ローカルのみ・保存時刻を往復できる', () async {
      final store = ComposeDraftStore(accountKey: 'mastodon://a@example');
      await store.save(
        const ComposeDraft(
          text: '本文',
          scope: PostScope.unlisted,
          sensitive: true,
          localOnly: true,
        ),
        now: fixedNow,
      );

      final restored = await ComposeDraftStore(
        accountKey: 'mastodon://a@example',
      ).restore();

      expect(restored!.scope, PostScope.unlisted);
      expect(restored.sensitive, isTrue);
      expect(restored.localOnly, isTrue);
      expect(restored.savedAt, fixedNow);
    });

    /// ⚠ 本文だけ戻して公開範囲が既定へ落ちると、**気づかず広い範囲へ投げる**。
    /// 保存していない（旧スロット由来の）ときは null にして、画面側が既定を
    /// 上書きしないようにする。
    test('scope を保存していなければ null で返す（既定を上書きさせない）', () async {
      final store = ComposeDraftStore(accountKey: 'mastodon://a@example');
      await store.save(const ComposeDraft(text: '本文'), now: fixedNow);

      final restored = await store.restore();
      expect(restored!.scope, isNull);
    });

    test('save は no-op のとき null を返す（画面が「保存した」と嘘をつかない）', () async {
      final store = ComposeDraftStore();
      await store.clear();

      expect(
        await store.save(const ComposeDraft(text: 'x'), now: fixedNow),
        isNull,
      );
    });
  });

  group('アカウント別スロット (#964)', () {
    test('別アカウントの下書きは見えない', () async {
      await ComposeDraftStore(
        accountKey: 'mastodon://a@example',
      ).save(const ComposeDraft(text: 'A の書きかけ'), now: fixedNow);

      final b = await ComposeDraftStore(
        accountKey: 'misskey://b@example',
      ).restore();

      expect(b, isNull, reason: 'A の本文が B の新規投稿画面に出てきていた');
    });

    test('アカウント削除でそのスロットだけ消える', () async {
      await ComposeDraftStore(
        accountKey: 'mastodon://a@example',
      ).save(const ComposeDraft(text: 'A'), now: fixedNow);
      await ComposeDraftStore(
        accountKey: 'misskey://b@example',
      ).save(const ComposeDraft(text: 'B'), now: fixedNow);

      await ComposeDraftStore.clearForAccount('mastodon://a@example');

      expect(
        await ComposeDraftStore(accountKey: 'mastodon://a@example').restore(),
        isNull,
      );
      expect(
        (await ComposeDraftStore(
          accountKey: 'misskey://b@example',
        ).restore())!.text,
        'B',
        reason: '巻き添えで消してはいけない',
      );
    });

    /// 旧版から上げたユーザーの書きかけを黙って捨てない。
    test('旧グローバルスロットは最初に読んだアカウントへ引き取る', () async {
      await ComposeDraftStore().save(
        const ComposeDraft(text: '旧スロットの本文'),
        now: fixedNow,
      );

      final adopted = await ComposeDraftStore(
        accountKey: 'mastodon://a@example',
      ).restore();
      expect(adopted!.text, '旧スロットの本文');

      // 引き取ったので旧スロットは空。別アカウントが二度目の引き取りをしない。
      expect(await ComposeDraftStore().restore(), isNull);
      expect(
        await ComposeDraftStore(accountKey: 'misskey://b@example').restore(),
        isNull,
        reason: '移行は 1 度きり。全アカウントへ配ってはいけない',
      );
    });
  });
}
