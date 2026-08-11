import 'package:capsicum/src/service/compose_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #966: 投稿フォームのローカル自動保存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      await store.save(const ComposeDraft(text: '投稿した本文'));
      await store.clear();

      await store.save(const ComposeDraft(text: '投稿した本文'));

      expect(store.discarded, isTrue);
      expect(await ComposeDraftStore().restore(), isNull);
    });

    test('clear は添付件数も消す（次の復元で古い注記を出さない）', () async {
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '本文', attachmentCount: 3));
      await store.clear();

      final next = ComposeDraftStore();
      await next.save(const ComposeDraft(text: '次の本文'));

      final restored = await next.restore();
      expect(restored!.text, '次の本文');
      expect(restored.attachmentCount, 0);
    });

    test('添付ゼロで保存すれば件数もゼロ', () async {
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '本文'));
      expect((await store.restore())!.attachmentCount, 0);
    });

    test('本文が空でも CW だけ生きていれば復元対象', () async {
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '', cwEnabled: true));

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
      await ComposeDraftStore().save(const ComposeDraft(text: 'hello'));

      // 画面 A / B とも同じ下書きを復元。
      final a = ComposeDraftStore();
      final b = ComposeDraftStore();
      expect((await a.restore())!.text, 'hello');
      expect((await b.restore())!.text, 'hello');

      // B が投稿 → clear。A は破棄済みではない（別インスタンス）。
      await b.clear();

      // A が離脱 → 保存を試みるが、世代が進んでいるので書き戻さない。
      await a.save(const ComposeDraft(text: 'hello'));

      expect(await ComposeDraftStore().restore(), isNull);
    });

    test('#969: clear 後に新しい画面が restore→save すれば自動保存は復活する', () async {
      await ComposeDraftStore().save(const ComposeDraft(text: '投稿した本文'));

      final posted = ComposeDraftStore();
      await posted.restore();
      await posted.clear();

      // clear 後に開いた新しい画面。復元は空だが、以降の保存は効く。
      final fresh = ComposeDraftStore();
      expect(await fresh.restore(), isNull);
      await fresh.save(const ComposeDraft(text: '新しい下書き'));

      expect((await ComposeDraftStore().restore())!.text, '新しい下書き');
    });

    test('#969: restore を挟まない単発 save は従来どおり書ける（世代ガードで塞がない）', () async {
      // 世代を一度進めておく（別画面の投稿相当）。
      final prior = ComposeDraftStore();
      await prior.save(const ComposeDraft(text: '前の本文'));
      await prior.clear();

      // restore を通らないインスタンスは基準世代 null なので、現世代を採用して
      // 通常どおり保存できる（standalone 契約を壊さない）。
      final store = ComposeDraftStore();
      await store.save(const ComposeDraft(text: '単発保存'));

      expect((await ComposeDraftStore().restore())!.text, '単発保存');
    });
  });
}
