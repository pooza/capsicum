import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../service/entitlement_token_store.dart';
import '../util/exception_scrub.dart';
import 'supporter_status_provider.dart';

/// 利用権の見え方 (#597 / #1123)。
///
/// ⚠⚠ **relay が返す文字列を UI で直接比べない。**`status` は relay 側の語彙
/// （`unverified` / `active` / `grace` / `billing_retry` / `expired` / `revoked`）で、
/// ⚠ **増えることがある**（#63 が状態を足す）。⚠⚠ **UI が綴りで分岐すると、
/// 知らない値が来たときに黙って「未購入」に落ちる** —— 買った人に「買ってください」
/// と出すのが最悪なので、**知らない値は「有効」側に倒す。**
enum EntitlementView {
  /// 手元に利用権が無い（買っていない / 端末の保存が消えた）。
  absent,

  /// 使える。⚠ **relay がまだ検証できていない `unverified` もここ**
  /// （判定は relay の仕事で、クライアントは止めない・#1121）。
  active,

  /// ⚠ **支払いが通っていないが、まだ止まっていない**（猶予・課金リトライ）。
  /// **気づける形で出す**のがこの状態の存在理由。
  grace,

  /// 失効した（解約・期限切れ・返金）。
  expired,
}

/// relay の `status` を [EntitlementView] へ畳む。
///
/// ⚠ **知らない値は [EntitlementView.active]。**「買った人に買わせる」ほうが、
/// 「失効した人に気づかせ損ねる」より重い —— 前者は**取り返しがつかない誤案内**
/// （二重購入）で、後者は relay 側のゲートが実際に止めるので必ず気づく。
EntitlementView entitlementViewOf(String? status) {
  return switch (status?.toLowerCase()) {
    null || '' => EntitlementView.absent,
    'expired' || 'revoked' => EntitlementView.expired,
    'grace' || 'billing_retry' => EntitlementView.grace,
    _ => EntitlementView.active,
  };
}

class EntitlementStatus {
  const EntitlementStatus({
    this.view = EntitlementView.absent,
    this.expiresAt,
    this.isRefreshing = false,
  });

  final EntitlementView view;

  /// relay が持っている期限（文字列のまま。⚠ 表示にしか使わない）。
  final String? expiresAt;

  /// relay へ問い合わせ中。
  final bool isRefreshing;

  EntitlementStatus copyWith({
    EntitlementView? view,
    Object? expiresAt = _keep,
    bool? isRefreshing,
  }) => EntitlementStatus(
    view: view ?? this.view,
    expiresAt: identical(expiresAt, _keep)
        ? this.expiresAt
        : expiresAt as String?,
    isRefreshing: isRefreshing ?? this.isRefreshing,
  );

  static const Object _keep = Object();
}

/// 手元の利用権と、relay 側の現在の状態 (#1123)。
///
/// ⚠ **手元の保存を先に見せてから relay へ問い合わせる。**通信を待たせると、
/// **圏外で画面が空になる**（プッシュ不達の切り分けはこの画面から始まるので、
/// 通信できないときこそ何か出ている必要がある）。
class EntitlementStatusNotifier extends Notifier<EntitlementStatus> {
  @override
  EntitlementStatus build() {
    scheduleMicrotask(refresh);
    return const EntitlementStatus(isRefreshing: true);
  }

  /// 手元 → relay の順で読み直す。
  Future<void> refresh() async {
    final local = await _loadLocal();
    if (local == null) {
      state = const EntitlementStatus(view: EntitlementView.absent);
      return;
    }
    // ⚠ まず手元の値で描く（通信を待たせない）。
    state = EntitlementStatus(
      view: entitlementViewOf(local.status),
      expiresAt: local.expiresAt,
      isRefreshing: true,
    );

    try {
      final json = await ref
          .read(supporterRelayClientProvider)
          .fetchEntitlement(local.token);
      if (json == null) {
        // ⚠⚠ **404 は「失効」ではない。**relay が知らない token ＝ 手元の保存が
        // 古い / 壊れている。⚠ **勝手に消さない** —— 消すと再登録の手掛かりごと
        // 失う。表示は手元の値のまま、問い合わせ中の印だけ下ろす。
        state = state.copyWith(isRefreshing: false);
        return;
      }
      final fresh = EntitlementToken.fromRelay(json);
      if (fresh != null) await EntitlementTokenStore.save(fresh);
      state = EntitlementStatus(
        view: entitlementViewOf(fresh?.status ?? local.status),
        expiresAt: fresh?.expiresAt ?? local.expiresAt,
      );
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('entitlement.status', 'refresh_failed');
          scope.fingerprint = [
            'entitlement.status.refresh',
            e.runtimeType.toString(),
          ];
        },
      );
      // ⚠ 手元の値を残したまま印だけ下ろす（通信の失敗で「未購入」に見せない）。
      state = state.copyWith(isRefreshing: false);
    }
  }

  Future<EntitlementToken?> _loadLocal() async {
    try {
      return await EntitlementTokenStore.load();
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('entitlement.status', 'load_failed');
          scope.fingerprint = ['entitlement.status.load'];
        },
      );
      return null;
    }
  }
}

final entitlementStatusProvider =
    NotifierProvider<EntitlementStatusNotifier, EntitlementStatus>(
      EntitlementStatusNotifier.new,
    );
