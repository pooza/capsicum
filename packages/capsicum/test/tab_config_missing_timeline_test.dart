import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1278: タイムラインの種類を増やしたとき、保存済みのタブ設定にも載せる。
///
/// ⚠ 載らないと、タブ管理に出てこないので**表示に切り替える手段が無い**。
void main() {
  test('⚠⚠ 保存済みの設定に無い種類は、隠した状態で末尾に足す', () {
    const saved = [
      TabConfigEntry(tab: TimelineTab(TimelineType.home), visible: true),
      TabConfigEntry(tab: TimelineTab(TimelineType.local), visible: true),
      TabConfigEntry(tab: TimelineTab(TimelineType.social), visible: true),
      TabConfigEntry(tab: TimelineTab(TimelineType.federated), visible: false),
      TabConfigEntry(
        tab: TimelineTab(TimelineType.directMessages),
        visible: true,
      ),
      TabConfigEntry(tab: NotificationsTab(), visible: false),
    ];

    final result = withMissingTimelineTabs(saved);

    expect(result.take(saved.length), saved, reason: '既存の並びと表示は変えない');
    final added = result.skip(saved.length).toList();
    expect(added.map((e) => e.tab), [const TimelineTab(TimelineType.remote)]);
    expect(added.single.visible, isFalse, reason: '頼んでいないタブを増やさない');
  });

  test('全部あれば何も足さない', () {
    final full = [
      for (final type in TimelineType.values)
        TabConfigEntry(tab: TimelineTab(type), visible: true),
    ];
    expect(withMissingTimelineTabs(full), full);
  });

  test('新規の既定ではリモートのみは隠してある', () {
    final remote = defaultTabConfig.singleWhere(
      (e) => e.tab == const TimelineTab(TimelineType.remote),
    );
    expect(remote.visible, isFalse);
  });
}
