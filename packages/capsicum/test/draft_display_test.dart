import 'package:capsicum/src/ui/util/draft_display.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #963: サーバー下書きの一覧表記。
///
/// 眼目は **`/drafts` 画面と compose のクイックチューザで同じ見え方になること**。
/// 同じ下書きが 2 か所に出るので、片方だけ表記を直すと「画面によって見え方が違う」
/// になる。整形をこのヘルパへ寄せ、両方がここを通る形にした。
void main() {
  Draft draft({
    String? content,
    List<Attachment> attachments = const [],
    DateTime? createdAt,
  }) => Draft(
    id: 'x',
    content: content,
    attachments: attachments,
    createdAt: createdAt ?? DateTime(2026, 8, 15, 9, 5),
  );

  Attachment attachment(String id) => Attachment(
    id: id,
    url: 'https://example/$id',
    type: AttachmentType.image,
  );

  group('draftBodyPreview', () {
    test('本文があればそのまま出す', () {
      expect(draftBodyPreview(draft(content: 'こんにちは')), 'こんにちは');
    });

    test('前後の空白は落とす', () {
      expect(draftBodyPreview(draft(content: '  こんにちは  ')), 'こんにちは');
    });

    /// ⚠ 改行は畳まない。呼び出し側が maxLines: 2 で 2 行見せているため
    /// （テンプレート側は 1 行なので畳んでいる）。
    test('改行は畳まない（2 行まで見せる側の都合）', () {
      expect(draftBodyPreview(draft(content: '1 行目\n2 行目')), '1 行目\n2 行目');
    });

    test('本文が無い / 空白だけなら「（本文なし）」', () {
      expect(draftBodyPreview(draft()), '（本文なし）');
      expect(draftBodyPreview(draft(content: '')), '（本文なし）');
      expect(draftBodyPreview(draft(content: '   \n ')), '（本文なし）');
    });
  });

  group('draftSubtitle', () {
    test('添付が無ければ日時だけ', () {
      expect(draftSubtitle(draft()), '2026/8/15 09:05');
    });

    test('添付があれば件数を添える', () {
      expect(
        draftSubtitle(draft(attachments: [attachment('a'), attachment('b')])),
        '2026/8/15 09:05 ・ 添付2件',
      );
    });

    test('時刻は 2 桁ゼロ埋め（日付は埋めない）', () {
      expect(
        draftSubtitle(draft(createdAt: DateTime(2026, 1, 2, 3, 4))),
        '2026/1/2 03:04',
      );
    });
  });
}
