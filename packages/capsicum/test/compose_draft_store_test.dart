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
  });
}
