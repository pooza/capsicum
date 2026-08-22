import 'package:capsicum/src/service/compose_draft_store.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
