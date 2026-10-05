import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../service/entitlement_token_store.dart';
import '../service/push_registration_service.dart';
import '../util/exception_scrub.dart';
import 'account_manager_provider.dart';
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

  /// ⚠ **返金済みだが、決済済みの期間が残っている**ので**まだ届く**
  /// (#1123・relay#63 の `entitled_refunded`)。
  ///
  /// ⚠⚠ **[expired] に混ぜられない。**relay はこの行を**通す**ので、失効と
  /// 同じ文面を出すと**届いているのに「届かなくなります」と言う**ことになる
  /// （2026-10-03 に実際にそうなっていた）。⚠ **期限を併記する**のがこの状態の
  /// 存在理由で、「返金したのにまだ使えるのはなぜ」という問いにも答えになる。
  refunded,

  /// 失効した（解約・期限切れ・返金後に期間も切れた）。
  expired,

  /// ⚠⚠ **プリセットサーバーのアカウントを持っているので、無条件に使える**
  /// (#1232・2026-10-05 pooza)。
  ///
  /// 🔴 **以前は [absent] に落ちていた。**`EntitlementView` が**買ったかどうか**
  /// しか見ておらず、プリセット利用者に「利用権がありません／ご購入が必要です」
  /// と出していた。⚠⚠ **`docs/product-policy.md` の不変条件（プリセットの
  /// 利用者には決して課金しない・課金の状態を見せるだけでも破れる）に違反
  /// しており、障害として扱う水準**だった。
  ///
  /// ⚠⚠ **「利用権 ＝ 購入したもの」ではない。**利用権は**リレーを使える状態**で、
  /// プリセットにログイン済みなら無条件に満たされる。⚠ **「プリセット以外でも
  /// 使えるようになる権利」という区分は存在しない** —— プリセットを 1 つでも
  /// 持てば、非プリセットのアカウントも含めて全部無償（relay のゲートの
  /// `preset` 判定）。
  preset,
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

/// relay が返した判定（`reason`）を使って [entitlementViewOf] を**補正**する
/// (#1123・relay#63)。
///
/// ⚠⚠ **`status` だけでは relay と違う結論になる。**relay はゲートで
/// `expires_at` も見るようになったので、
///
/// | 形 | `status` だけの判定 | relay の実際 |
/// | --- | --- | --- |
/// | 猶予（未払い） | 「まだ届いている」 | 🔴 **止まる** |
/// | `active` のまま期限切れ | 「有効」 | 🔴 **拒否**（更新の通知を取りこぼした形） |
/// | 返金済みで期間が残っている | 「失効」 | 🔴 **通す**（払った分の権利は否定しない） |
///
/// ⚠ **`reason` は全部は使わない。**`no_entitlement` を「未購入」に倒すと、
/// **relay がまだ検証できていない購入（`unverified`）を「買ってください」と
/// 案内する** —— 二重購入は取り返しがつかないので、そこは従来どおり `status`
/// 側の判断（知らない値は「有効」）に任せる。**補正するのは上の 3 つだけ。**
///
/// ⚠⚠ **`revoked` を `status` 側で [EntitlementView.refunded] に倒さない。**
/// 期間が残っているかは `expires_at` を見た relay しか知らないので、`reason` が
/// 無い回（古い relay）に「まだ使えます」と言うと**嘘になりうる**。⚠ 補正は
/// `reason` が来たときだけ。
///
/// ⚠ **古い relay は `reason` を返さない**（本番が追いつくまで）。その場合は
/// null で渡ってくるので、従来の判定がそのまま効く。
EntitlementView entitlementViewOfRelay({String? status, String? reason}) {
  return switch (reason?.toLowerCase()) {
    'unpaid' => EntitlementView.grace,
    'expired' => EntitlementView.expired,
    'entitled_refunded' => EntitlementView.refunded,
    _ => entitlementViewOf(status),
  };
}

/// relay の `expires_at` を画面に出せる形へ。読めなければ null (#1123)。
///
/// ⚠⚠ **relay は UTC を `2026-11-03 12:34:56` の形で返す**（タイムゾーンの印が
/// 無い。⚠ relay 側のメソッド名は `iso8601_ms` だが、実際の書式は
/// `strftime('%Y-%m-%d %H:%M:%S')` で Apple / Play 共通）。⚠⚠ **`DateTime.parse`
/// はこれを端末のローカル時刻として読むので、JST では 9 時間ずれる。**`Z` を
/// 補って UTC として読み、[DateTime.toLocal] でローカルへ直す。
///
/// ⚠ **読めなければ null を返して、文面から日付を落とす。**生の文字列や
/// `null` をそのまま見せない。
String? formatEntitlementExpiry(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return null;
  // ⚠ 既に印が付いている形（`...Z` / `+09:00`）はそのまま解釈させる。
  final hasZone = RegExp(r'([Zz]|[+-]\d{2}:?\d{2})$').hasMatch(text);
  final parsed = DateTime.tryParse(hasZone ? text : '${text}Z');
  if (parsed == null) return null;
  final local = parsed.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
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
    // ⚠⚠ **プリセットを最初に見る (#1232)。**プリセットのアカウントがあれば
    // 利用権は**無条件にある**ので、手元の保存も relay の状態も関係ない。
    // ⚠ **relay へ問い合わせない** —— 判定に要らないうえ、プリセットのみの
    // 利用者に利用権の通信を走らせない方針（`push_notification_settings_screen`
    // の門と同じ理由）。
    if (PushRegistrationService.hasPresetAmong(
      ref.read(accountManagerProvider).accounts,
    )) {
      state = const EntitlementStatus(view: EntitlementView.preset);
      return;
    }

    // ⚠ **プリセットの人が購入済みでも、購入の状態は出さない**（2026-10-05
    // pooza 判断）。⚠⚠ **解約はもともとストア側でしかできない**（`capsicum-site`
    // の特定商取引法に基づく表記）ので、アプリから消えても失われる導線は無い。
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
      // ⚠ `reason` は relay が計算した判定（relay#63）。⚠⚠ **手元に保存しない**
      // —— 保存すると「いつの判定か」が分からなくなる。画面に出すのは
      // **いま問い合わせた結果**だけで、圏外のときは `status` 側の判定に戻る。
      state = EntitlementStatus(
        view: entitlementViewOfRelay(
          status: fresh?.status ?? local.status,
          reason: json['reason'] as String?,
        ),
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
