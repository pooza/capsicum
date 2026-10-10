import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../service/device_install_id.dart';
import '../service/entitlement_token_store.dart';
import '../service/push_registration_service.dart';
import '../util/exception_scrub.dart';
import 'account_manager_provider.dart';
import 'entitlement_status_provider.dart';
import 'supporter_purchase_backend.dart';
import 'supporter_status_provider.dart';

export 'supporter_purchase_backend.dart'
    show supporterSubscriptionProductId, supporterTipProductIds;

/// 購入導線を出すプラットフォーム (#428 D-1)。iOS / Android に加え、#598 で
/// macOS (Mac App Store IAP) を解放。iOS / macOS は Universal Purchase
/// (同一 App レコード) のため ASC の消耗型 3 商品をそのまま共有し、
/// `in_app_purchase` も macOS を in_app_purchase_storekit で公式サポートする。
/// Windows は #599 でストア IAP（Microsoft Store）を解放するが、購入は
/// **Store からインストールされたコピーでのみ**成立するため、買えるかどうかは
/// 実行時に商品問い合わせが通るか（[SupporterPurchaseState.isAvailable]）で
/// 決まる（⚠ 入口は問い合わせに繋がず常に出す・[supporterEntryVisibleProvider]）。
/// この getter はコンパイル時に backend の有無だけを表す。Linux はストア IAP 不在。
bool get supporterPurchaseSupported =>
    Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

/// この OS に投げ銭の課金 backend が存在するか（サポート画面のハード無効表示を
/// 出すかの判定）。Windows は Store 版のみ購入成立だが backend 自体は存在する
/// ため true にし、実際に購入できるか（Store 版か・商品を取得できたか）は
/// [SupporterPurchaseState.isAvailable] で別途出し分ける (#599 §E-2)。
bool get supporterPurchaseHasBackend =>
    supporterPurchaseSupported || Platform.isWindows;

/// 有償リレーの利用権サブスクを**買える**プラットフォーム (#1122)。
///
/// ⚠ **投げ銭（[supporterPurchaseSupported]）と同じではない。**
///
/// | | |
/// | --- | --- |
/// | iOS / macOS / Android | ✅ `in_app_purchase` がサブスクを扱える |
/// | ⚠ **Windows** | **後回し**。Microsoft Store のサブスクは消耗型と別経路で、
///   既存の自前 channel から作り直しになる（設計書 フェーズ 4 のストア順序） |
/// | Linux | ⚠ **買える経路が無い**（AppImage 直配） |
///
/// ⚠⚠ **これが false の OS では入口を出さない。**出すと「押しても買えない」に
/// なる —— 買えないことは**商品説明と案内で伝える**（#1124）。
bool get subscriptionPurchaseSupported => supporterPurchaseSupported;

/// 購入・復元の結果の種類。
///
/// ⚠⚠ **「失敗」を 1 つに畳まない**（リリース前レビュー・2026-10-06）。以前は
/// `error` しか無く、サブスクの失敗はすべて「利用権を有効にできませんでした」と
/// 出していた —— **決済が通らなかっただけ**の回にも、**復元に失敗した**回にも
/// 同じ文面で、利用者が次に何をすべきか読み取れなかった。
enum SupporterPurchaseOutcomeKind {
  success,
  canceled,

  /// ストアでの購入が成立しなかった（決済の拒否・ストアとの通信の失敗など）。
  error,

  /// ⚠ **購入は成立したが、利用権を発行できなかった**（relay へ届かない等）。
  /// **「購入できなかった」と言ってはいけない**ほう。
  entitlementError,

  /// 復元の要求そのものが失敗した。
  restoreError,

  /// 復元を要求したが、**ストアが購入を 1 件も返さなかった。**
  /// ⚠ 失敗ではないが、**何も出さないと「押しても何も起きない」に見える**
  /// （添え書きが「通知が届かないときにお試しください」と案内している口なので、
  /// 困っている人ほどここへ来る）。
  nothingToRestore,
}

/// 直近の購入試行結果。UI（段 3）がスナックバー等で提示する。
class SupporterPurchaseOutcome {
  final SupporterPurchaseOutcomeKind kind;

  /// error 時のみ。スクラブ済みの短い説明（生レスポンスは載せない）。
  final String? message;

  /// 利用権サブスクの結果か (#1122)。投げ銭なら false。
  ///
  /// ⚠⚠ **UI の文言が変わるので要る。**投げ銭の成功は「サポーターになりました」
  /// だが、⚠ **サブスクでそれを出すと、買ったものを取り違えて伝える。**
  final bool isSubscription;

  const SupporterPurchaseOutcome(
    this.kind, {
    this.message,
    this.isSubscription = false,
  });
}

/// `lastOutcome` を「保持／クリア／差し替え」の三状態で扱う sentinel
/// （[DriveState.loadMoreError] と同じ手法）。
const Object _keepOutcome = Object();

/// [SupporterPurchaseState.subscription] を「保持／クリア／差し替え」で扱う
/// sentinel。⚠ **`??` で済ませない** —— それだと**一度見つけた商品を消せない**ので、
/// ストアから消えた（審査で落ちた・配信を止めた）あとも**買えない入口が残る**。
const Object _keepSubscription = Object();

class SupporterPurchaseState {
  /// ストア課金が利用可能か（非対応 OS / ストア不通なら false）。
  final bool isAvailable;

  /// 商品情報の問い合わせ中。
  final bool isLoadingProducts;

  /// ストアから取得済みの商品（[supporterTipProductIds] 順）。
  final List<ProductDetails> products;

  /// 有償リレーの利用権サブスク商品 (#1122)。⚠ 取得できなければ null
  /// （ストア未登録・審査前・サブスク非対応 OS）。**null なら入口を出さない。**
  final ProductDetails? subscription;

  /// 手元に利用権トークンがあるか (#1121 / #1122)。
  ///
  /// ⚠ **「購入したか」ではなく「この端末が利用権を持っているか」。**
  /// 購入はストアアカウントに属し、1 つの購入を複数端末で使える（設計書 2-A）。
  final bool hasEntitlement;

  /// 購入処理中（ボタン二度押し抑止に使う）。
  final bool purchaseInProgress;

  /// 直近の購入試行結果。未試行なら null。
  final SupporterPurchaseOutcome? lastOutcome;

  const SupporterPurchaseState({
    this.isAvailable = false,
    this.isLoadingProducts = false,
    this.products = const [],
    this.subscription,
    this.hasEntitlement = false,
    this.purchaseInProgress = false,
    this.lastOutcome,
  });

  SupporterPurchaseState copyWith({
    bool? isAvailable,
    bool? isLoadingProducts,
    List<ProductDetails>? products,
    Object? subscription = _keepSubscription,
    bool? hasEntitlement,
    bool? purchaseInProgress,
    Object? lastOutcome = _keepOutcome,
  }) => SupporterPurchaseState(
    isAvailable: isAvailable ?? this.isAvailable,
    isLoadingProducts: isLoadingProducts ?? this.isLoadingProducts,
    products: products ?? this.products,
    subscription: identical(subscription, _keepSubscription)
        ? this.subscription
        : subscription as ProductDetails?,
    hasEntitlement: hasEntitlement ?? this.hasEntitlement,
    purchaseInProgress: purchaseInProgress ?? this.purchaseInProgress,
    lastOutcome: identical(lastOutcome, _keepOutcome)
        ? this.lastOutcome
        : lastOutcome as SupporterPurchaseOutcome?,
  );
}

/// 消耗型 IAP の購入フロー (#428 段 2)。
///
/// 商品タイプ（消耗型）・課金プラグインをこの内側に閉じ、成功時は
/// [supporterStatusProvider] の `markTipped` を呼ぶだけ。UI はバッジを
/// [isSupporterProvider] で見るので、購入手段の詳細を知らない。
/// 購入は画面を閉じた後に確定し得るためアプリ寿命で購読する
/// （autoDispose しない）。
/// 課金 backend の差し替え口 (#1231)。⚠ 既定は OS ごとの実装。
/// **検査から「返ってこないストア」を食わせる**ために provider にした。
final supporterPurchaseBackendProvider = Provider<SupporterPurchaseBackend>(
  (ref) => createSupporterPurchaseBackend(),
);

class SupporterPurchaseNotifier extends Notifier<SupporterPurchaseState> {
  /// ⚠⚠ **ストアの往復が返ってこないときに画面を固着させない** (#1231)。
  /// 実測の往復は Play が 311〜345ms・Apple が約 1,084ms（[#1122](https://github.com/pooza/capsicum/issues/1122)）
  /// なので、遅い回線を見込んでも十分に長い。
  static const storeTimeout = Duration(seconds: 15);

  /// 手元のキーホルダ読み出し。⚠ 本来は即座に返る。
  ///
  /// ⚠ 値は [EntitlementStatusNotifier.localTimeout] が正本（同じ読みを両方が
  /// するので、上限を別々に持たない・#1237）。
  static const localTimeout = EntitlementStatusNotifier.localTimeout;

  late final SupporterPurchaseBackend _backend;
  StreamSubscription<SupporterPurchaseEvent>? _sub;

  /// サブスクの購入イベントを受け取った回数 (#1234)。
  ///
  /// [restoreAndReregister] が「復元で購入が返ったか」を知るためだけに使う。
  /// ⚠ **処理の完了ではなく到着で数える**（[_onSubscriptionPurchased] の先頭）——
  /// 完了を待つと relay への通信ぶん遅れ、その間に二重に登録してしまう。
  int _subscriptionEventCount = 0;

  /// いま処理している最中のサブスクの購入イベントの数 (#1237)。
  ///
  /// 復元の後始末が「まだ発行の途中か」を知るために見る。
  /// - 途中なら、ボタンを戻さない（押し直すと 2 本目の発行が 1 本目と relay の
  ///   枠を取り合う）
  /// - 途中なら、「復元できる購入はありません」と言わない（数秒後に「復元しました」
  ///   で上書きされ、結果が一瞬矛盾して見えていた）
  int _subscriptionInFlight = 0;

  /// [restoreAndReregister] が、自分の登録のやり直しを待っている最中か。
  /// その間は、購入イベントの側がボタンを戻さない（復元の finally が戻す）。
  bool _restoreReregistering = false;

  /// [loadProducts] の世代 (#1248)。時間切れのあとに届いた答えを反映するとき、
  /// その間に読み直しが始まっていないかを見分ける。
  int _loadGeneration = 0;

  @override
  SupporterPurchaseState build() {
    // 課金経路を OS ごとの backend に閉じる (#599 §E-3)。iOS / Android / macOS は
    // in_app_purchase、Windows は Windows.Services.Store の自前 channel。
    _backend = ref.read(supporterPurchaseBackendProvider);
    if (!_backend.isSupported) {
      return const SupporterPurchaseState();
    }
    _sub = _backend.purchaseEvents.listen(
      _onEvent,
      onError: (Object e, StackTrace st) {
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('supporter.purchase', 'stream_error');
            scope.fingerprint = [
              'supporter.purchase.stream',
              e.runtimeType.toString(),
            ];
          },
        );
        // 購入ストリーム自体が崩壊した場合も purchaseInProgress を戻す。
        // buy() 後にここへ来ると、各購入ステータス分岐を一切経由しないため
        // フラグがリセットされず投げ銭ボタンが固着する。
        state = state.copyWith(
          purchaseInProgress: false,
          lastOutcome: const SupporterPurchaseOutcome(
            SupporterPurchaseOutcomeKind.error,
          ),
        );
      },
    );
    ref.onDispose(() {
      // 待っている読み込みの続きを、破棄後に `state` へ書かせない (#1248)。
      _loadGeneration++;
      _sub?.cancel();
      _backend.dispose();
    });
    // 商品問い合わせを起動（結果は state に反映）。
    scheduleMicrotask(loadProducts);
    return const SupporterPurchaseState(isLoadingProducts: true);
  }

  /// ストアから商品情報を取得する。画面再表示時に UI から再呼び出し可。
  Future<void> loadProducts() async {
    if (!_backend.isSupported) return;
    final generation = ++_loadGeneration;
    final elapsed = Stopwatch()..start();
    state = state.copyWith(isLoadingProducts: true);
    try {
      final availability = _backend.isAvailable();
      final bool available;
      try {
        available = await availability.timeout(storeTimeout);
      } on TimeoutException {
        // 画面は下の catch で固着から抜けるが、**問い合わせそのものは捨てない**。
        _adoptLateAvailability(availability, generation, elapsed);
        rethrow;
      }
      if (generation != _loadGeneration) return;
      if (!available) {
        state = state.copyWith(isAvailable: false, isLoadingProducts: false);
        return;
      }
      await _loadAvailableProducts(generation);
    } catch (e, st) {
      _reportLoadFailure(e, st);
      // ⚠ 読み直しが始まっていれば、そちらの結果を古い失敗で巻き戻さない。
      if (generation != _loadGeneration) return;
      state = state.copyWith(isAvailable: false, isLoadingProducts: false);
    }
  }

  /// 時間切れのあとに届いた「利用可能か」の答えを、捨てずに反映する (#1248)。
  ///
  /// 🔴 **2.0.0 では、Windows の「サポート」の入口が丸ごと消えた。**#1231 の
  /// 時間切れは、切れた時点で `isAvailable: false` に確定させ、**遅れて返った
  /// 結果を誰も読まなかった**。Windows の入口は `isAvailable` だけで出し分けて
  /// いて（[supporterEntryVisibleProvider]）、読み直しの口は投げ銭画面の中に
  /// しか無い ＝ **入口が出ないので、読み直しにも行けない**。
  ///
  /// ⚠ **Windows で起動のたびに時間切れになっていた原因は、遅さではなかった。**
  /// Microsoft Store の往復は実測で 1.0〜1.5 秒（2026-10-10・製品版のパッケージ
  /// の中で計測）。返った結果をネイティブのワーカーが捨てていたので、Dart には
  /// 答えが届かなかった（`flutter_window.cpp` の `window_alive`）。この関数は
  /// 「本当に遅いストア」への備えとして残す。
  ///
  /// ⚠⚠ **時間切れは「画面を固着させない」ためのもので、「使えない」の判定では
  /// ない。**答えが出たら、その答えに従う。
  ///
  /// ⚠ **ここから `loadProducts()` を呼び直さない。**Windows の backend は
  /// `isAvailable()` のたびにストアへ問い合わせるので、遅いストアでは「時間切れ →
  /// 遅れて到着 → 問い合わせ直し → 時間切れ」が回り続ける。届いた答えの続き
  /// （[_loadAvailableProducts]）だけを進める。
  void _adoptLateAvailability(
    Future<bool> availability,
    int generation,
    Stopwatch elapsed,
  ) {
    unawaited(() async {
      final bool available;
      try {
        available = await availability;
      } catch (e) {
        // 遅れて失敗した。時間切れの時点で「利用不可」にしてあるので、そのまま。
        if (generation == _loadGeneration) {
          _reportLateAvailability(
            'load_products_late_failed',
            elapsed,
            errorType: e.runtimeType.toString(),
          );
        }
        return;
      }
      // 待っている間に読み直しが始まっていれば、そちらが正。
      if (generation != _loadGeneration) return;
      // ⚠⚠ **「採用した」以外の結末も残す。**この修正は Windows 実機で確かめて
      // おらず、時間切れの記録は効いた回にも出るので、**残さないと「まだ返って
      // いない」と「返ったが使えなかった」が Sentry から見分けられない**。
      if (!available) {
        _reportLateAvailability('load_products_late_unavailable', elapsed);
        return;
      }
      _reportLateAvailability('load_products_late', elapsed);
      try {
        await _loadAvailableProducts(generation);
      } catch (e, st) {
        _reportLoadFailure(e, st);
        if (generation != _loadGeneration) return;
        state = state.copyWith(isAvailable: false, isLoadingProducts: false);
      }
    }());
  }

  void _reportLateAvailability(
    String outcome,
    Stopwatch elapsed, {
    String? errorType,
  }) {
    Sentry.captureMessage(
      'supporter.purchase.$outcome',
      level: SentryLevel.info,
      withScope: (scope) {
        scope.setTag('supporter.purchase', outcome);
        scope.fingerprint = ['supporter.purchase.$outcome'];
        // ⚠ 上限を決め直す材料（Microsoft Store の往復は未実測）。
        scope.setContexts('supporter_purchase', {
          'available_after_ms': elapsed.elapsedMilliseconds,
          'error_type': ?errorType,
        });
      },
    );
  }

  /// ストアが利用可能と分かったあとの続き: 商品を取り、利用権を反映する。
  ///
  /// ⚠⚠ **待つたびに [generation] を見直す** (#1248)。入口で 1 回見るだけでは、
  /// 商品を待っている間に始まった読み直しの結果を、**あとから返った古い続きが
  /// 上書きする**（成功なら古い商品で、時間切れなら「利用不可」で）。
  Future<void> _loadAvailableProducts(int generation) async {
    // ⚠ **投げ銭とサブスクを 1 回の問い合わせで取る** (#1122)。分けると
    // 往復が 2 倍になるうえ、⚠⚠ **片方だけ失敗した状態**を扱う分岐が増える。
    final products = await _backend
        .queryProducts({
          ...supporterTipProductIds,
          if (subscriptionPurchaseSupported) supporterSubscriptionProductId,
        })
        .timeout(storeTimeout);
    if (generation != _loadGeneration) return;
    final byId = {for (final p in products) p.id: p};
    // 定義順（金額昇順）に整列。ストアに存在しない ID は黙って除外する。
    final ordered = [
      for (final id in supporterTipProductIds)
        if (byId[id] != null) byId[id]!,
    ];
    // ⚠⚠ **商品が取れた時点で先に画面へ出す (#1231)。**🔴 以前は
    // `hasEntitlement: await _loadEntitlement()` と**`copyWith` の引数の中で
    // 待って**いたため、**キーホルダの読み出しが返らないだけで、取れている
    // 商品もホイールの裏に隠れたまま**になった。⚠ ストアの往復と手元の
    // 読み出しは**本来無関係**。
    state = state.copyWith(
      isAvailable: true,
      isLoadingProducts: false,
      products: ordered,
      // ⚠ **取れなければ null に戻す。**ストアから消えたあとも入口が残ると、
      // 押しても買えないボタンになる（[_keepSubscription] の説明）。
      subscription: byId[supporterSubscriptionProductId],
    );
    // ⚠ 利用権は後から反映する（これが遅くても画面は出ている）。
    // ⚠⚠ **先に待ってから `state` を読む。**`state.copyWith(x: await …)` と
    // 書くと、Dart は**レシーバの `state` を先に評価する**ので、待っている間に
    // 変わった `purchaseInProgress` / `lastOutcome` を古い値で巻き戻す。
    final hasEntitlement = await _loadEntitlement();
    if (generation != _loadGeneration) return;
    state = state.copyWith(hasEntitlement: hasEntitlement);
  }

  void _reportLoadFailure(Object e, StackTrace st) {
    Sentry.captureException(
      scrubException(e),
      stackTrace: st,
      withScope: (scope) {
        // ⚠⚠ **タイムアウトを「失敗」に混ぜない (#1231)。**ストアが
        // 返ってこない事象は**無言で画面が固着する**という別の壊れ方で、
        // 件数の推移も原因も違う。⚠ 分けておかないと、**誰も気づけない**。
        scope.setTag(
          'supporter.purchase',
          e is TimeoutException
              ? 'load_products_timeout'
              : 'load_products_failed',
        );
        scope.fingerprint = [
          'supporter.purchase.load_products',
          e.runtimeType.toString(),
        ];
      },
    );
  }

  /// 手元の利用権トークンの有無を読む (#1121 / #1122)。
  ///
  /// ⚠ **失敗を握りつぶして false にしない。**キーホルダが読めない事故で
  /// 「未購入」に見えると、**買った人にもう一度買わせる**ことになる。読めなければ
  /// **直前の値を保つ**（呼び出し側が `hasEntitlement` を渡さない形になる）。
  Future<bool> _loadEntitlement() async {
    try {
      // ⚠ **ここにも上限を置く (#1231)。**キーホルダは本来すぐ返るが、
      // **返らない事故が起きたときに利用権の表示が永久に古いまま**になる。
      // 🔴 **[EntitlementTokenStore.load] ではなく `loadOrThrow`。**前者は
      // 読めなくても null を返すので、下の catch（直前の値を保つ）に**一度も
      // 来ていなかった**（リリース前レビューで判明・2026-10-06）。
      return await EntitlementTokenStore.loadOrThrow().timeout(localTimeout) !=
          null;
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'entitlement_load_failed');
          scope.fingerprint = [
            'supporter.purchase.entitlement_load',
            e.runtimeType.toString(),
          ];
        },
      );
      return state.hasEntitlement;
    }
  }

  /// 利用権サブスクを購入する (#1122)。
  ///
  /// ⚠ **結果はイベント経由**（[_onEvent]）。ここでは開始だけ。
  Future<void> subscribe(ProductDetails product) async {
    if (!_backend.isSupported || state.purchaseInProgress) return;
    if (!subscriptionPurchaseSupported) return;

    state = state.copyWith(purchaseInProgress: true, lastOutcome: null);
    try {
      await _backend.buySubscription(product);
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'subscribe_failed');
          scope.fingerprint = [
            'supporter.purchase.subscribe',
            e.runtimeType.toString(),
          ];
        },
      );
      state = state.copyWith(
        purchaseInProgress: false,
        lastOutcome: const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.error,
          isSubscription: true,
        ),
      );
    }
  }

  /// ストアから利用権を取り直す (#1219)。
  ///
  /// ⚠⚠ **「買い直す」ではない。**ストアに `restorePurchases` を投げ、過去の購入を
  /// `restored` として流し直してもらう。既存の経路（[_handleSubscription]）が
  /// `POST /entitlements` をやり直すので、**relay 側の判定が最新になる。**
  ///
  /// 使う場面は 2 つ:
  ///
  /// - **機種変更・再インストール**。利用権トークンは `ThisDeviceOnly` の secure
  ///   storage にあり**バックアップに含まれない**ので、ストアから引き直すしかない
  /// - 🔴 **`unverified` で固着したとき。**`POST /entitlements` は購入イベントが
  ///   流れたときだけ走るので、**起動し直しても再検証は起きない**
  ///   （2026-10-04 に実機で踏んだ・#1220）
  ///
  /// ⚠ **投げ銭（消耗型）は復元の対象外。**文面も「利用権」に限ること ——
  /// サポーターバッジが戻ると読めてはいけない。
  /// 手元の利用権トークンを捨てる (#1219)。
  ///
  /// ⚠⚠ **購入そのものは消えない。**ストアの購読は解約されず、
  /// [restoreEntitlement] で引き直せる。消えるのは**この端末の保存**だけ。
  ///
  /// ## なぜ要るか
  ///
  /// 🔴 **取り直しが空振りすると抜けられない状態が残る。**relay が認めない
  /// トークン（返金済み・別のストアアカウントで買った・保存が壊れた）を持って
  /// いると:
  ///
  /// 1. `status` が読めない値なので [EntitlementView] は**「有効」側へ倒れる**
  ///    （買った人に「買ってください」と出さないための判断・#1123）
  /// 2. そのため**購入ボタンが出ない**
  /// 3. [restoreEntitlement] は復元すべき購入が無ければ**イベントが 1 つも
  ///    流れてこない**ので、何も起きず**トークンも残る**
  ///
  /// → これを捨てると `absent` に戻り、買い直せるようになる。
  ///
  /// ⚠⚠ **自動では捨てない。**`EntitlementStatusNotifier.refresh` が 404 で
  /// 「勝手に消さない」としているのと同じ理由で、**通信の失敗やストア側の一過性
  /// の不調で有効な利用権を捨てると、再登録の手掛かりごと失う**。⚠ **利用者が
  /// 確認してから**押す口にしてある（画面側がダイアログを出す）。
  ///
  /// 戻り値は「消せたか」。⚠ **false は、消そうとして消せなかった回だけ**
  /// (#1247)。その回は `hasEntitlement` も落とさない（記録は残っている）。
  Future<bool> forgetEntitlement() async {
    if (state.purchaseInProgress) return true;
    // ⚠⚠ **消す前に、応答待ちの読み直しを無効にする**（2 回目の差分レビュー・
    // 2026-10-06）。消している最中に着いた古い応答が、記録を保存し直せた。
    ref.read(entitlementStatusProvider.notifier).invalidatePending();
    if (!await EntitlementTokenStore.clear()) return false;
    // ⚠ 画面の「購入を復元する / 記録を消す」の出し分けはこの値を見るので、
    // **保存を消したらここも落とす**（残すとボタンが消えない）。
    state = state.copyWith(hasEntitlement: false);
    return true;
  }

  Future<void> restoreEntitlement() async {
    if (!_backend.isSupported || state.purchaseInProgress) return;
    if (!subscriptionPurchaseSupported) return;

    state = state.copyWith(purchaseInProgress: true, lastOutcome: null);
    try {
      await _backend.restore();
      // ⚠ **ここで成功を宣言しない。**復元すべき購入が無ければイベントは
      // 1 つも流れてこないので、`lastOutcome` は `_onEvent` 側に委ねる。
      // ⚠⚠ **代わりにフラグだけ戻す** —— 戻さないとボタンが固着する。
      // ⚠ ただし、返ってきた購入の発行がまだ途中なら戻さない (#1237)。
      // そちらは [_issueEntitlementFor] の出口が戻す。
      state = state.copyWith(purchaseInProgress: _subscriptionInFlight > 0);
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'restore_failed');
          scope.fingerprint = [
            'supporter.purchase.restore',
            e.runtimeType.toString(),
          ];
        },
      );
      state = state.copyWith(
        purchaseInProgress: false,
        lastOutcome: const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.restoreError,
          isSubscription: true,
        ),
      );
    }
  }

  /// 購入を復元し、通知の登録をやり直す (#1234)。画面の「購入を復元する」の実体。
  ///
  /// ⚠⚠ **以前は 2 つのボタンに分かれていた**（「利用権を取り直す」＝ストアへの
  /// 復元 /「購入を確認して登録し直す」＝登録のやり直し）。名前から違いが読めず、
  /// しかも**復元は成功すると登録のやり直しまで行う**ので、違いが出るのは
  /// **ストアが購入を返さなかったとき**だけだった。1 つにまとめ、
  /// **復元の結果にかかわらず登録はやり直される**ようにした。
  ///
  /// | 復元の結果 | 登録をやり直すのは |
  /// | --- | --- |
  /// | 購入が返った | 既存の経路（[_onSubscriptionPurchased] → [_completeAndReregister]） |
  /// | 返らなかった・失敗した | ここ |
  ///
  /// ⚠⚠ **両方で打たない。**購入が返った回にここでも打つと、relay へ登録が
  /// 2 本飛ぶ（#1217 で `register.created` が 0.6 秒差で 2 本出た形）。
  /// ⚠ 購入イベントが復元の完了より**遅れて**届いた場合は 2 本になりうるが、
  /// 登録は上書きなので害は無い（順序はストアの実装次第で保証が無い）。
  ///
  /// ⚠ **課金は発生しない。**ストアへ頼むのは過去の購入の流し直しだけ。
  ///
  /// 戻り値は「復元で購入が返ったか」。
  Future<bool> restoreAndReregister() async {
    if (state.purchaseInProgress) return false;

    final before = _subscriptionEventCount;
    await restoreEntitlement();
    if (_subscriptionEventCount != before) return true;

    // ⚠ 登録は端末のトークンを待つことがある（最大 10 秒）。その間に押し直せない
    // ようにする。
    state = state.copyWith(purchaseInProgress: true);
    _restoreReregistering = true;
    try {
      final accounts = ref.read(accountManagerProvider).accounts;
      if (accounts.isNotEmpty) {
        await PushRegistrationService.registerAllAccounts(
          accounts,
          hasPreset: ref.read(hasPresetAccountProvider),
        );
      }
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'restore_reregister_failed');
          scope.fingerprint = ['supporter.purchase.restore_reregister'];
        },
      );
    } finally {
      _restoreReregistering = false;
      // 🔴 **復元できる購入が無かったことを伝える**（リリース前レビュー
      // 2026-10-06）。以前は何も立てなかったので、ボタンが一瞬無効になって
      // 戻るだけで、**「押しても何も起きない」に見えた**。
      // ⚠ 復元の要求そのものが失敗した回は、[restoreEntitlement] が既に
      // `restoreError` を立てているので上書きしない。
      //
      // ⚠⚠ **購入イベントが遅れて届いていたら、「無かった」と言わない** (#1237)。
      // 上の登録は端末のトークンを最大 10 秒待つので、その間に届くことがある。
      // 以前はここで「復元できる購入はありません」を立て、数秒後に発行が済むと
      // 「復元しました」で上書きされていた。⚠ 発行の途中ならボタンも戻さない。
      state = state.copyWith(
        purchaseInProgress: _subscriptionInFlight > 0,
        lastOutcome: outcomeAfterRestoreFallback(
          state.lastOutcome,
          arrivedLate: _subscriptionEventCount != before,
        ),
      );
    }
    return false;
  }

  /// 指定 SKU を消耗型として購入する。結果は購入イベント経由で
  /// [state] / [SupporterStatusNotifier] に反映される。
  Future<void> buy(ProductDetails product) async {
    if (!_backend.isSupported || state.purchaseInProgress) return;
    state = state.copyWith(purchaseInProgress: true, lastOutcome: null);
    try {
      await _backend.buy(product);
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'buy_failed');
          scope.fingerprint = [
            'supporter.purchase.buy',
            e.runtimeType.toString(),
          ];
        },
      );
      state = state.copyWith(
        purchaseInProgress: false,
        lastOutcome: const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.error,
        ),
      );
    }
  }

  /// backend が正規化した購入イベント 1 件を状態遷移へ落とす。
  ///
  /// in_app_purchase の `List<PurchaseDetails>` 単位の処理を、backend 抽象
  /// （[SupporterPurchaseEvent]）の 1 件単位に置き換えたもの。トランザクション
  /// 完了（in_app_purchase の completePurchase / Windows の消費報告）は
  /// [SupporterPurchaseBackend.complete] に委ね、ローカル永続化が成立した
  /// 購入だけを確定させる。
  Future<void> _onEvent(SupporterPurchaseEvent event) async {
    switch (event.status) {
      case SupporterPurchaseEventStatus.pending:
        state = state.copyWith(purchaseInProgress: true);
        return;
      case SupporterPurchaseEventStatus.canceled:
        // ユーザー操作。例外ではないので breadcrumb のみ。
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'supporter.purchase',
            level: SentryLevel.info,
            message: 'canceled',
          ),
        );
        state = state.copyWith(
          purchaseInProgress: false,
          lastOutcome: const SupporterPurchaseOutcome(
            SupporterPurchaseOutcomeKind.canceled,
          ),
        );
        return;
      case SupporterPurchaseEventStatus.error:
        Sentry.captureException(
          scrubException(Exception('purchase error')),
          withScope: (scope) {
            scope.setTag('supporter.purchase', 'purchase_error');
            scope.fingerprint = [
              'supporter.purchase.error',
              event.errorCode ?? 'unknown',
            ];
          },
        );
        state = state.copyWith(
          purchaseInProgress: false,
          lastOutcome: SupporterPurchaseOutcome(
            SupporterPurchaseOutcomeKind.error,
            // 🔴 **サブスクの購入かどうかを載せる**（リリース前レビュー
            // 2026-10-06）。以前は常に false だったので、プッシュ通知設定画面
            // （サブスクの結果だけを出す）では、**ストアがエラーを返しても
            // 何も表示されなかった**。
            isSubscription: event.productId == supporterSubscriptionProductId,
          ),
        );
        return;
      case SupporterPurchaseEventStatus.purchased:
        // ⚠⚠ **商品で分ける (#1122)。**購入イベントの stream は投げ銭と共用
        // （backend は 1 つ）なので、**ここで振り分けないと投げ銭の経路が
        // サブスクの購入を「投げ銭」として記録する。**
        if (event.productId == supporterSubscriptionProductId) {
          await _onSubscriptionPurchased(event);
          return;
        }
        // 消耗型につきレシート検証は最小（ストアを信頼）。サーバー側
        // 保持に移行した時点で検証経路を抽象層内に追加する（B-4）。
        var persisted = true;
        try {
          await ref
              .read(supporterStatusProvider.notifier)
              .markTipped(sku: event.productId);
          state = state.copyWith(
            purchaseInProgress: false,
            lastOutcome: const SupporterPurchaseOutcome(
              SupporterPurchaseOutcomeKind.success,
            ),
          );
        } catch (e, st) {
          // 課金はストア側で成立済みだが、ローカル記録の永続化に失敗。
          // purchaseInProgress を必ず戻してボタン固着を防ぐ（#298 同型）。
          // complete を呼ばないことで、in_app_purchase は次回起動の再配信、
          // Windows は次回購入時の AlreadyPurchased で markTipped を再試行する。
          persisted = false;
          Sentry.captureException(
            scrubException(e),
            stackTrace: st,
            withScope: (scope) {
              scope.setTag('supporter.purchase', 'mark_tipped_failed');
              scope.fingerprint = [
                'supporter.purchase.mark_tipped',
                e.runtimeType.toString(),
              ];
            },
          );
          state = state.copyWith(
            purchaseInProgress: false,
            lastOutcome: const SupporterPurchaseOutcome(
              SupporterPurchaseOutcomeKind.error,
            ),
          );
        }
        // ストアトランザクションを確定させる（未確定だと再配信され続ける /
        // 消耗型残高が残る）。永続化に失敗した購入はあえて確定させず再試行に委ねる。
        if (persisted && event.needsCompletion) {
          try {
            await _backend.complete(event);
          } catch (e, st) {
            // 確定（completePurchase / 消費報告）に失敗。ローカルのバッジは
            // 成立済み。未確定トランザクションは再配信 / AlreadyPurchased で
            // 拾い直せるため、観測だけして本筋は止めない。
            Sentry.captureException(
              scrubException(e),
              stackTrace: st,
              withScope: (scope) {
                scope.setTag('supporter.purchase', 'complete_failed');
                scope.fingerprint = [
                  'supporter.purchase.complete',
                  e.runtimeType.toString(),
                ];
              },
            );
          }
        }
        return;
    }
  }

  /// サブスクが購入（または復元）された (#1122)。
  ///
  /// **購入 → relay が利用権トークンを発行 → 手元へ保存 → `/register` に
  /// 載せ直す**、の 4 段。⚠⚠ **最後まで行かないと「買ったのに使えない」**になる
  /// ——`/register` はトークンを**登録時に**読むので、載せ直さない限り relay 側の
  /// 判定は購入前のままになる。
  ///
  /// ⚠ **ストアのトランザクションは、利用権の保存が成立してから確定させる**
  /// （投げ銭と同じ考え方）。途中で失敗したら確定させず、⚠ **次回起動の再配信**で
  /// 拾い直す —— 確定してしまうと、**購入は成立しているのに利用権が無い**状態が
  /// 再試行の手掛かりごと消える。
  Future<void> _onSubscriptionPurchased(SupporterPurchaseEvent event) async {
    _subscriptionEventCount++;
    _subscriptionInFlight++;
    // ⚠ **発行のあいだは押し直せないようにする** (#1237)。購入の経路は `buy` が
    // 立てているが、**復元の経路は復元の要求が返った時点で戻していた**ので、
    // 発行が relay の送り直しで数秒かかる間にもう一度「復元」を押せた。
    state = state.copyWith(purchaseInProgress: true);
    try {
      await _issueEntitlementFor(event);
    } finally {
      _subscriptionInFlight--;
      // ⚠⚠ **最後の 1 件が抜けるときに、フラグを必ず戻す**（リリース前レビュー・
      // 2026-10-10）。発行の出口が戻したあと、登録のやり直し
      // （[_completeAndReregister]・端末のトークンを最大 10 秒待つ）の最中に
      // 復元の側が `_subscriptionInFlight > 0` を見て立て直すと、戻す者が
      // 居なくなり、**購入も復元も再起動まで押せなくなっていた**。
      // ⚠ 復元の側が自分の登録を待っている間は、そちらの finally に任せる。
      if (_subscriptionInFlight == 0 &&
          !_restoreReregistering &&
          state.purchaseInProgress) {
        state = state.copyWith(purchaseInProgress: false);
      }
    }
  }

  /// [_onSubscriptionPurchased] の中身。失敗の出口は `purchaseInProgress` を戻す。
  /// ⚠ **ほかの購入イベントの発行が残っていれば戻さない**（`> 1` は自分を除いた
  /// 残り）。1 件目が済んだ時点で戻すと、2 件目の発行中に押し直せた (#1237)。
  /// ⚠ 成功の出口は戻さない（後始末が済むまで押させない）。
  Future<void> _issueEntitlementFor(SupporterPurchaseEvent event) async {
    final store = entitlementStoreName();
    final purchaseId = event.purchaseId;
    // ⚠ どちらも無ければ利用権を引けない。**成功に見せない。**
    if (store == null || purchaseId == null || purchaseId.isEmpty) {
      Sentry.captureException(
        scrubException(Exception('subscription purchase without an id')),
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'entitlement_missing_id');
          scope.fingerprint = ['supporter.purchase.entitlement_missing_id'];
        },
      );
      state = state.copyWith(
        purchaseInProgress: _subscriptionInFlight > 1,
        lastOutcome: const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.entitlementError,
          isSubscription: true,
        ),
      );
      return;
    }

    try {
      final json = await ref
          .read(supporterRelayClientProvider)
          .issueEntitlementToken(
            store: store,
            purchaseId: purchaseId,
            deviceId: await DeviceInstallId.get(),
            productId: event.productId,
          );
      final token = EntitlementToken.fromRelay(json);
      if (token == null) throw StateError('relay returned no entitlement');
      // ⚠ 応答待ちの読み直しに、いま受け取った token を古い値で上書きさせない。
      ref.read(entitlementStatusProvider.notifier).invalidatePending();
      await EntitlementTokenStore.save(token);
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'entitlement_issue_failed');
          scope.fingerprint = entitlementIssueFingerprint(e);
          final reason = relayBusyReasonOf(e);
          if (reason != null) scope.setTag('relay.reason', reason);
        },
      );
      state = state.copyWith(
        purchaseInProgress: _subscriptionInFlight > 1,
        lastOutcome: const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.entitlementError,
          isSubscription: true,
        ),
      );
      return; // ⚠ 確定させない（再配信で拾い直す）
    }

    // ⚠ **ここではボタンを戻さない**（PR #1256 の Codex P2）。このあとの
    // ストアの確定と登録のやり直しが済むまで、押し直すと 2 本目が 1 本目と
    // 競う。戻すのは [_onSubscriptionPurchased] の finally。
    state = state.copyWith(
      hasEntitlement: true,
      lastOutcome: const SupporterPurchaseOutcome(
        SupporterPurchaseOutcomeKind.success,
        isSubscription: true,
      ),
    );
    await _completeAndReregister(event);
  }

  /// ストアのトランザクションを確定させ、`/register` を打ち直す (#1122)。
  ///
  /// ⚠ **どちらも失敗しても購入は成立している**ので、観測だけして本筋は止めない。
  /// ⚠ 再登録が落ちても、**次回起動の登録でトークンは載る**（手元に保存済み）。
  Future<void> _completeAndReregister(SupporterPurchaseEvent event) async {
    if (event.needsCompletion) {
      try {
        await _backend.complete(event);
      } catch (e, st) {
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('supporter.purchase', 'subscription_complete_failed');
            scope.fingerprint = ['supporter.purchase.subscription_complete'];
          },
        );
      }
    }
    try {
      final accounts = ref.read(accountManagerProvider).accounts;
      if (accounts.isNotEmpty) {
        await PushRegistrationService.registerAllAccounts(
          accounts,
          hasPreset: ref.read(hasPresetAccountProvider),
        );
      }
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'reregister_failed');
          scope.fingerprint = ['supporter.purchase.reregister'];
        },
      );
    }
  }
}

// ⚠⚠ **ストアの判定は `supporter_purchase_backend.dart` の
// [entitlementStoreName] に移した (#1220)。**`purchase_id` に何を送るかと同じ軸
// なので、別々に持つと「store は google なのに Apple の値を送る」形になり、
// **Play のレシート検証と RTDN が黙って外れる**（2026-10-04 に本番で踏んだ）。

final supporterPurchaseProvider =
    NotifierProvider<SupporterPurchaseNotifier, SupporterPurchaseState>(
      SupporterPurchaseNotifier.new,
    );

/// 設定に投げ銭エントリ（購入導線）を出すか (#428 D-1 / #599 §E-2)。
///
/// iOS / Android / macOS は常に出す（[supporterPurchaseSupported]）。
///
/// ⚠⚠ **Windows も常に出す (#1248・2026-10-10 pooza)。**🔴 以前は「商品の
/// 問い合わせが通った（= Store 版）ときだけ出す」（#599 §E-2(a)）だったが、
/// **製品版 2.0.0 / 2.0.1 で問い合わせが返らず、入口が丸ごと消えた。**入口を
/// 問い合わせの成否に繋ぐと、問い合わせが壊れた回に**読み直しの口（投げ銭画面の
/// 中にある）へも行けなくなる**。
///
/// - 守る相手だった自己署名 MSIX の直配は #760 で公式案内をやめており、製品として
///   配っているのは Store 版だけ。買えない入口が出るのは開発ビルドと手で入れた
///   `.msix` に限られ、そこでは投げ銭画面が「ご利用いただけません」と伝える。
/// - ⚠ **ここで購入 provider を watch しない。**watch すると起動のたびに Store へ
///   問い合わせる。問い合わせは投げ銭画面を開いたときだけでよい。
final supporterEntryVisibleProvider = Provider<bool>((ref) {
  if (supporterPurchaseSupported) return true;
  if (Platform.isWindows) return true;
  // 課金 backend が無い OS（現状 Linux）は Web の支援先を案内するので、入口
  // 自体は出す (#893)。ストア版に Web リンクを出さない判断は投げ銭画面側で行う。
  // backend 非提供のターゲットが増えても追従漏れしないよう、Platform.isLinux
  // 直書きではなく backend の有無で判定する (#924)。
  if (!supporterPurchaseHasBackend) return true;
  return false;
});

/// 復元で購入が返らず、登録だけやり直した回の締めくくりに出す結果 (#1237)。
///
/// - 既に結果が立っていれば、それを残す（復元の要求の失敗・遅れて届いた購入の成功）
/// - ⚠ **購入イベントが遅れて届いていたら、何も立てない**（[arrivedLate]）。
///   結果は発行が済んだ時点でイベントの側が立てる。ここで「無かった」と言うと、
///   数秒後に「復元しました」で上書きされる
/// - どちらでもなければ「復元できる購入はありません」
SupporterPurchaseOutcome? outcomeAfterRestoreFallback(
  SupporterPurchaseOutcome? current, {
  required bool arrivedLate,
}) =>
    current ??
    (arrivedLate
        ? null
        : const SupporterPurchaseOutcome(
            SupporterPurchaseOutcomeKind.nothingToRestore,
            isSubscription: true,
          ));

/// relay が「塞がっている」と断った回なら、その理由の語。それ以外は null。
///
/// ⚠ **応答の値をそのまま返さない。**Sentry のタグと fingerprint に載せるので、
/// 知っている固定の語だけを通す。
String? relayBusyReasonOf(Object error) {
  if (error is! DioException) return null;
  final data = error.response?.data;
  if (data is! Map) return null;
  return data['reason'] == 'verification_busy' ? 'verification_busy' : null;
}

/// 利用権の発行に失敗した回の、Sentry の fingerprint。
///
/// ⚠⚠ **型だけで束ねない**（2 回目の差分レビュー・2026-10-06）。以前は
/// `DioException` の 1 件に、送り直しても塞がっていた 503・設定が無い 503・
/// 共有シークレットの不一致（401）・relay の 5xx・圏外が**全部入っていた**ので、
/// 件数から「relay が埋められている」を見分けられなかった。ステータスと、
/// 塞がっていた回の印で分ける。
List<String> entitlementIssueFingerprint(Object error) {
  final status = error is DioException ? error.response?.statusCode : null;
  final reason = relayBusyReasonOf(error);
  return [
    'supporter.purchase.entitlement_issue',
    error.runtimeType.toString(),
    if (status != null) 'status_$status',
    ?reason,
  ];
}
