import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/server_config_provider.dart';
import 'post_scope_display.dart';

/// タイムラインの種類の表示名 (#1304)。
///
/// ⚠⚠ **表はここ 1 本。**以前はタブの見出し（`home_menu.dart` の `tabLabel`）と
/// タブ管理（`tab_management_sheet.dart`）に同じ表が 2 本あり、Mastodon 用の
/// 上書きも 2 本あった。#1278 でリモートのみを足したときに、両方へ同じ文字列を
/// 足している。
const _labels = {
  TimelineType.home: 'ホーム',
  TimelineType.social: 'ソーシャル',
  TimelineType.federated: 'グローバル',
  // Mastodon だけ (#1278)。本家の列設定の「リモートのみ表示」と、capsicum の
  // 「連合」を合わせた語（本家の Web の「ほかのサーバー」は「連合」と並べると
  // 何の一部か読めない）。
  TimelineType.remote: '連合（リモートのみ）',
};

/// Mastodon は「グローバル」でなく「連合」。
const _mastodonOverrides = {TimelineType.federated: '連合'};

/// [type] の表示名。
///
/// - ローカルはサーバーごとの呼び名（[localTimelineNameProvider]・デフォルト
///   ハッシュタグのサーバーでは置き換わる）
/// - ダイレクトは公開範囲の表記（[postScopeLabel]）。[adapter] はその呼び分けに使う
String timelineTypeLabel(
  WidgetRef ref,
  TimelineType type, {
  required bool isMastodon,
  DecentralizedBackendAdapter? adapter,
}) {
  if (type == TimelineType.local) return ref.watch(localTimelineNameProvider);
  if (type == TimelineType.directMessages) {
    return postScopeLabel(PostScope.direct, adapter);
  }
  return (isMastodon ? _mastodonOverrides[type] : null) ??
      _labels[type] ??
      type.name;
}
