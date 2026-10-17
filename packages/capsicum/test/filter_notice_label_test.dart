import 'package:capsicum/src/ui/util/filter_labels.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 畳んだ投稿の行の文言 (#1293)。
///
/// ⚠ SNS の本来の用語に揃える（`docs/filter-management-plan.md` 決定済み事項 4）。
/// 以前は Misskey のワードミュートでも「フィルター: ワードミュート」と出ていた。
void main() {
  test('Mastodon のフィルターは「フィルター: 名前」', () {
    final verdict = resolveFilterMatches(const [
      FilterMatch(action: FilterAction.warn, title: 'ネタバレ'),
    ], null)!;
    expect(verdict.wordMute, isFalse);
    expect(filterNoticeLabel(verdict), 'フィルター: ネタバレ');
  });

  test('名前が無ければ「フィルター: 非表示」', () {
    final verdict = resolveFilterMatches(const [
      FilterMatch(action: FilterAction.warn),
    ], null)!;
    expect(filterNoticeLabel(verdict), 'フィルター: 非表示');
  });

  test('⚠⚠ Misskey のワードミュートは「フィルター」を付けない', () {
    final verdict = resolveFilterMatches(
      const [
        FilterMatch(
          action: FilterAction.hide,
          title: 'ハードワードミュート',
          wordMute: true,
        ),
      ],
      null,
      weakenHide: true,
    )!;
    expect(verdict.wordMute, isTrue);
    expect(filterNoticeLabel(verdict), 'ハードワードミュート');
  });

  test('ワードミュートとフィルターが混ざれば「フィルター: …」', () {
    final verdict = resolveFilterMatches(const [
      FilterMatch(action: FilterAction.warn, title: 'ワードミュート', wordMute: true),
      FilterMatch(action: FilterAction.warn, title: 'ネタバレ'),
    ], null)!;
    expect(verdict.wordMute, isFalse);
    expect(filterNoticeLabel(verdict), 'フィルター: ワードミュート、ネタバレ');
  });
}
