import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../provider/account_manager_provider.dart';
import '../provider/entitlement_status_provider.dart';

/// プリセットの利用者か (#1358)。`true` / `false`。
const presetUserTag = 'preset_user';

/// 利用権の状態 (#1358)。値は [relayEntitlementTagOf]。
const relayEntitlementTag = 'relay_entitlement';

/// Sentry のスコープへタグを書く。テストが差し替える。
@visibleForTesting
void Function(String key, String value) sentryUserTagWriter = _writeToScope;

void _writeToScope(String key, String value) {
  Sentry.configureScope((scope) => scope.setTag(key, value));
}

/// [relayEntitlementTag] の値。まだ読めていなければ null（タグを付けない）。
///
/// ⚠⚠ **購入者と読むのは `active` / `grace` だけ。**`unverified` は購入の証拠では
/// ないので（`EntitlementToken` の doc）、[EntitlementView.active] に畳まずに分ける。
/// ⚠ relay の応答の文字列はそのまま出さず、知らない値は `other` に丸める。
String? relayEntitlementTagOf(EntitlementStatus status) {
  return switch (status.view) {
    // ⚠ 読み込み中の初期値は「持っていない」ではなく、まだ分からない。
    EntitlementView.absent => status.isRefreshing ? null : 'none',
    EntitlementView.preset => 'preset',
    EntitlementView.unknown => 'unknown',
    EntitlementView.grace => 'grace',
    EntitlementView.refunded => 'refunded',
    EntitlementView.expired => 'expired',
    EntitlementView.active => switch (status.relayStatus?.toLowerCase()) {
      'active' => 'active',
      'unverified' => 'unverified',
      _ => 'other',
    },
  };
}

/// [EntitlementStatusNotifier] の状態が変わったときに呼ぶ。
void writeRelayEntitlementTag(EntitlementStatus status) {
  final value = relayEntitlementTagOf(status);
  if (value != null) sentryUserTagWriter(relayEntitlementTag, value);
}

/// [presetUserTag] を、値が変わるたびにスコープへ入れる (#1358)。
///
/// ⚠⚠ **セッションの復元が終わってから読むこと。**復元の前はアカウントが空で
/// `false` に見えるので、起動直後の記録にプリセットの利用者でも `false` が付く。
/// 復元前の記録はタグ無しにして、「不明」と読む（2026-11-01 pooza）。
final sentryUserTagsProvider = Provider<void>((ref) {
  ref.listen<bool>(
    hasPresetAccountProvider,
    (_, hasPreset) => sentryUserTagWriter(presetUserTag, '$hasPreset'),
    fireImmediately: true,
  );
});
