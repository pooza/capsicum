import 'package:capsicum/src/service/compose_draft_store.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1195: 空の下書きが「下書きあり」として残り、触っていない公開範囲を固定する。
///
/// ⚠⚠ **`PopScope` の離脱時保存は無条件に走る**ので、**フォームを開いて何も
/// 打たずに閉じるだけ**で保存が呼ばれていた。`_save` が本文に `''` を書き、
/// `_read` の「キーが無ければ下書きなし」判定（`text == null && ...`）を抜けて
/// しまうため、**以後ずっと「下書きあり」**になる。
///
/// その状態で `scope` が戻されると、**利用者が一度も触っていない公開範囲が
/// 「選択」として固定され**、サーバー側で既定を変えても反映されない
/// （[#1185](https://github.com/pooza/capsicum/issues/1185) が効かない）。
///
/// ⚠ **#964 の守りは外さない** —— 利用者が選んだ公開範囲は、広い / 狭いに
/// 関わらずそのまま戻す。区別するのは「選んだ」か「既定のまま」か。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ComposeDraftStore store() => ComposeDraftStore(accountKey: 'mastodon://a@h');
  final now = DateTime.utc(2026, 10, 1, 12, 34);

  group('空の下書きは残さない (#1195)', () {
    // ⚠⚠ これが本丸。開いて閉じただけ＝本文も選択も無い。
    test('⚠⚠ 本文も選択も無ければ保存しない（開いて閉じただけ）', () async {
      final s = store();
      final savedAt = await s.save(
        ComposeDraft(text: '', scope: PostScope.public, chosen: const {}),
        now: now,
      );

      expect(savedAt, isNull, reason: '「自動保存 hh:mm」を出さない');
      expect(await s.restore(), isNull, reason: '下書きなしとして読める');
    });

    // ⚠ 公開範囲だけ変えて本文を書かずに閉じた場合は**選択なので残す**。
    test('⚠ 本文が無くても、選んだ設定があれば残す', () async {
      final s = store();
      final savedAt = await s.save(
        ComposeDraft(
          text: '',
          scope: PostScope.followersOnly,
          chosen: const {ComposeDraftStore.chosenScope},
        ),
        now: now,
      );

      expect(savedAt, isNotNull);
      final restored = await store().restore();
      expect(restored, isNotNull);
      expect(restored!.scope, PostScope.followersOnly);
      expect(restored.isChosen(ComposeDraftStore.chosenScope), isTrue);
    });

    // ⚠ 本文があれば従来どおり（#964 / #966 を壊していないこと）。
    test('本文があれば保存する（対照群）', () async {
      final s = store();
      expect(
        await s.save(
          ComposeDraft(text: 'やあ', scope: PostScope.public, chosen: const {}),
          now: now,
        ),
        isNotNull,
      );
      expect((await store().restore())?.text, 'やあ');
    });

    // ⚠⚠ **書かないだけでは足りない。**前回の本文が残ると「消したのに戻る」。
    test('⚠⚠ 空で保存すると、前に保存した本文も消える', () async {
      final s = store();
      await s.save(
        ComposeDraft(text: 'やあ', chosen: const {}),
        now: now,
      );
      expect((await store().restore())?.text, 'やあ');

      await s.save(
        ComposeDraft(text: '', chosen: const {}),
        now: now,
      );

      expect(await store().restore(), isNull);
    });

    // ⚠⚠ **修正前に書かれてしまった空の下書きが端末に残っている。**本文キーが
    // `''` で存在するので、読む側でも落とさないと次の保存まで直らない。
    test('⚠⚠ 既に書かれている空の下書きも、読む側で落とす', () async {
      SharedPreferences.setMockInitialValues({
        '${ComposeDraftStore.textKey}_mastodon://a@h': '',
        '${ComposeDraftStore.cwTextKey}_mastodon://a@h': '',
        '${ComposeDraftStore.scopeKey}_mastodon://a@h': 'public',
      });

      expect(
        await store().restore(),
        isNull,
        reason: '⚠ これが残ると、触っていない公開範囲が固定され続ける',
      );
    });
  });

  group('「選んだ」と「既定のまま」を分ける (#1195)', () {
    test('選んでいない設定は isChosen が false', () async {
      final s = store();
      await s.save(
        ComposeDraft(text: 'やあ', scope: PostScope.public, chosen: const {}),
        now: now,
      );

      final restored = await store().restore();
      expect(restored!.scope, PostScope.public, reason: '値そのものは残す');
      expect(
        restored.isChosen(ComposeDraftStore.chosenScope),
        isFalse,
        reason: '⚠ 呼ぶ側はこれを見て、いまの既定を引き直す',
      );
    });

    // ⚠⚠ **旧スロットとの互換は安全側へ。**印が無い＝「分からない」ときに
    // 「選んでいない」へ倒すと、#964 の守り（本文だけ戻して公開範囲が既定へ
    // 戻る事故）が外れる。
    test('⚠⚠ 印が無い旧スロットは「選んだ」に倒す', () async {
      SharedPreferences.setMockInitialValues({
        '${ComposeDraftStore.textKey}_mastodon://a@h': '書きかけ',
        '${ComposeDraftStore.scopeKey}_mastodon://a@h': 'followersOnly',
        // ⚠ chosen キーは無い
      });

      final restored = await store().restore();
      expect(restored!.chosen, isNull);
      expect(
        restored.isChosen(ComposeDraftStore.chosenScope),
        isTrue,
        reason: '⚠ #964 の守りを互換の都合で外さない',
      );
    });

    test('選んだ印は保存して読み戻せる', () async {
      final s = store();
      await s.save(
        ComposeDraft(
          text: 'やあ',
          scope: PostScope.direct,
          chosen: const {ComposeDraftStore.chosenScope},
        ),
        now: now,
      );

      final restored = await store().restore();
      expect(restored!.isChosen(ComposeDraftStore.chosenScope), isTrue);
      expect(restored.scope, PostScope.direct);
    });
  });

  group('ComposeDraft.isEmpty の線引き', () {
    test('本文・CW・添付・選択がすべて無ければ空', () {
      expect(const ComposeDraft(text: '', chosen: {}).isEmpty, isTrue);
    });

    test('⚠ 選択があれば空ではない', () {
      expect(
        const ComposeDraft(
          text: '',
          chosen: {ComposeDraftStore.chosenScope},
        ).isEmpty,
        isFalse,
      );
    });

    test('CW だけでも空ではない', () {
      expect(
        const ComposeDraft(text: '', cwText: '注意', chosen: {}).isEmpty,
        isFalse,
      );
      expect(
        const ComposeDraft(text: '', cwEnabled: true, chosen: {}).isEmpty,
        isFalse,
      );
    });

    // ⚠ 戻せない添付（ドライブ添付）しか無い場合も、件数が残っていれば空ではない。
    test('⚠ 添付の件数だけでも空ではない', () {
      expect(
        const ComposeDraft(text: '', attachmentCount: 1, chosen: {}).isEmpty,
        isFalse,
      );
    });

    // ⚠⚠ 旧スロット（印が無い）で本文も無いものは、残しても戻すものが無い。
    test('⚠⚠ 印が無くても、本文が無ければ空', () {
      expect(const ComposeDraft(text: '').isEmpty, isTrue);
    });
  });
}
