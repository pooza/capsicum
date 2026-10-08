import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #793: 接続インジケータを出すのは streaming する本線 TL だけ。タブ UI の
/// AppBar とデッキのカラム見出しが同じ判定を使う。
void main() {
  test('本線 TL はその種別を返す', () {
    for (final type in [
      TimelineType.home,
      TimelineType.local,
      TimelineType.social,
      TimelineType.federated,
    ]) {
      expect(streamIndicatorTimelineType(TimelineTab(type)), type);
    }
  });

  test('⚠ DM は出さない（Mastodon では購読しない）', () {
    expect(
      streamIndicatorTimelineType(
        const TimelineTab(TimelineType.directMessages),
      ),
      isNull,
    );
  });

  test('本線以外のタブは出さない', () {
    expect(streamIndicatorTimelineType(const HashtagTab('delmulin')), isNull);
    expect(streamIndicatorTimelineType(const ListTab(id: 'l1')), isNull);
    expect(streamIndicatorTimelineType(const ChannelTab(id: 'c1')), isNull);
  });
}
