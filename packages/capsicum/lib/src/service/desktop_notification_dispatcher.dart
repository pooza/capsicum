import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../model/account.dart';
import '../model/account_key.dart';
import '../platform/notification_subsystem/notification_subsystem.dart';
import '../platform/platform_info.dart';
import '../provider/account_manager_provider.dart';
import '../provider/announcement_provider.dart';
import '../provider/platform_providers.dart';
import '../ui/util/moderation_notification_text.dart';
import '../ui/util/notification_type_display.dart';
import '../ui/widget/content_parser.dart';
import '../util/exception_scrub.dart';
import '../util/notification_filter.dart';
import '../util/sentry_tag_hash.dart';
import 'bounded_key_set.dart';
import 'delivered_push_cleaner.dart';
import 'notification_dedup_channel.dart';
import 'notification_tag.dart';
import 'stream_connect_failure_reporter.dart';

/// デスクトップ 3 OS (macOS / Linux / Windows) で、ログイン中の各アカウントの
/// WebSocket 通知ストリーミング ([NotificationStreamSupport]) を OS ローカル
/// 通知 ([NotificationSubsystem]) に橋渡しする service (#569 / #675)。
///
/// アプリ起動中限定の通知配信。ネイティブ push (APNs #468 / WNS #474) とは
/// `notification.id` ベースの dedup で併存する。設計は
/// docs/desktop-notification-design.md を参照。
///
/// #675 で全ログインアカウントを並列購読するよう拡張（旧実装はアクティブ
/// アカウント 1 つだけ）。非アクティブなアカウント宛ての反応こそ通知で拾い
/// たい、という実用上の要請に応える。アカウント数ぶん WebSocket
/// (Mastodon user / Misskey main) が常駐する。
class DesktopNotificationDispatcher {
  DesktopNotificationDispatcher(this._ref);

  final Ref _ref;

  /// アカウントごとの通知ストリーム購読。[AccountKey] で同定し、アカウントの
  /// 増減 (ログイン / ログアウト) に追従して張り直す。アクティブ垢の切替では
  /// 既存購読を維持して WebSocket を無駄に切らない。
  final Map<AccountKey, StreamSubscription<Notification>> _subs = {};

  /// セッション内 dedup。native push と二重受信する通知を取りこぼさず
  /// 1 表示に抑える。`notification.id` はサーバーローカルでアカウント間で
  /// 衝突しうるため、account を含む複合キーで持つ。
  final _emittedKeys = BoundedKeySet('emitted', _maxTrackedKeys);

  /// APNs 先着で native 側 (macOS NotificationDedupPlugin) が表示済みの
  /// `username@host|notificationId` キー (#674)。[NotificationDedupChannel] の
  /// onRemotePresented で流入し、同じ通知の WebSocket 側 emit をスキップする。
  final _nativeShownKeys = BoundedKeySet('native_shown', _maxTrackedKeys);
  static const _maxTrackedKeys = 500;

  /// OS 通知本文の上限。OS 側でも truncate されるが念のため client 側でも切る。
  static const _maxBodyLength = 200;

  /// streaming 内部 error の観測 throttle。timeline_provider (#586) と同型で
  /// breadcrumb は毎回、captureException は性質ごとに 60s throttle して切断中の
  /// 連発 spam を防ぐ。全アカウント共通バケット (account 識別子は PII のため
  /// tag / fingerprint には載せない。host 分岐も入れない)。
  DateTime? _lastParseCapture;
  DateTime? _lastConnectCapture;
  static const _captureThrottle = Duration(seconds: 60);
  static const _captureThrottleAfterExhausted = Duration(hours: 1);
  bool _reconnectExhaustedReported = false;

  /// ログインアカウントの変化を listen し、購読集合を合わせる。
  /// desktop 以外では何もしない。
  void start() {
    if (!isDesktop) return;
    // APNs 先着分の逆方向 dedup (#674)。macOS 以外では channel が no-op。
    _ref.read(notificationDedupChannelProvider).onRemotePresented = (key) {
      _nativeShownKeys.add(key);
    };
    // 配信済み generic 通知の掃除役 (#673)。ここで read して常駐させ、
    // APNs 到着合図 (onRemoteArrived) の配線を起動時に済ませる。
    _ref.read(deliveredPushCleanerProvider);
    _ref.listen<AccountManagerState>(
      accountManagerProvider,
      (prev, next) => _reconcile(next.accounts),
      fireImmediately: true,
    );
  }

  /// 現在のログインアカウント集合に購読を合わせる。新規アカウントは購読を
  /// 開始し、消えたアカウントは購読を解除する。既存はそのまま維持する
  /// (アクティブ垢の切替だけでは張り替えない)。
  void _reconcile(List<Account> accounts) {
    final live = <AccountKey>{};
    for (final account in accounts) {
      final adapter = account.adapter;
      if (adapter is! NotificationStreamSupport) continue;
      live.add(account.key);
      if (_subs.containsKey(account.key)) continue; // 既に購読中
      debugPrint(
        'capsicum: push.desktop: subscribing notification stream '
        '(account=${sentrySafeAccount(account.key)} '
        'adapter=${adapter.runtimeType})',
      );
      _subscribedAt[account.key] = now();
      _subs[account.key] = (adapter as NotificationStreamSupport)
          .streamNotifications(
            onParseError: _onStreamParseError,
            onStreamError: (e, st) =>
                _onStreamConnectError(e, st, account.key.host),
            onReconnectExhausted: _onStreamReconnectExhausted,
            onConnectionEvent: (event) {
              _onStreamConnectionEvent(event, account.key.host);
              _trackConnection(account.key, event);
            },
          )
          .listen(
            (n) {
              _refreshAnnouncementsIfNeeded(account, n);
              _emit(account, n);
            },
            // ストリーム側の error は streaming 内 reconnect で吸収済み。
            // ここに届くのは controller close 等なので握りつぶす。
            onError: (_, _) {},
          );
    }
    final removed = _subs.keys.where((key) => !live.contains(key)).toList();
    for (final key in removed) {
      _subs.remove(key)?.cancel();
      _disconnectedAt.remove(key);
      _subscribedAt.remove(key);
      debugPrint(
        'capsicum: push.desktop: unsubscribed '
        '(account=${sentrySafeAccount(key)})',
      );
    }
  }

  /// 拾い直しの起点（アカウントごと・#1261）。つながっている間は持たない。
  /// ⚠ 切断を**検知した**時刻そのものではない（[_catchUpBaseline]）。
  final Map<AccountKey, DateTime> _disconnectedAt = {};

  /// 購読を始めた時刻（アカウントごと）。拾い直しの起点の下限に使う。
  final Map<AccountKey, DateTime> _subscribedAt = {};

  /// 切断を検知した時点から、拾い直しの起点を決める。
  ///
  /// ⚠⚠ **検知した時刻をそのまま起点にしない**（v2.2 のリリース前レビュー）。
  /// Wi-Fi の切り替えのようにエラーが来ないまま切れた回線は、ping の応答が
  /// 途切れるまで検知できない。実際に切れてから検知するまでの間に届いた通知は、
  /// 検知した時刻より前なので拾い直しから落ちていた —— #1261 が狙っている
  /// 短い切断そのものの場面。起点を [kSilentDisconnectAllowance] ぶん手前へ下げる。
  ///
  /// - 下げたぶん、切れる前に接続から受けた通知も入ってくるが、出す側の重複の
  ///   除去で落ちる
  /// - ⚠ **購読を始めた時刻より前へは下げない。**起動より前に届いた通知を
  ///   バナーで出さない
  DateTime _catchUpBaseline(AccountKey key) {
    final assumed = now().subtract(kSilentDisconnectAllowance);
    final subscribedAt = _subscribedAt[key];
    return subscribedAt != null && subscribedAt.isAfter(assumed)
        ? subscribedAt
        : assumed;
  }

  /// 時計の差し替え口（テスト用）。
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  /// 切れていた間に届いた通知を、つなぎ直したあとに拾い直す (#1261)。
  ///
  /// 接続の節目は [ReconnectingSocket] の語（`connected` / `disconnected`）で
  /// 届く。⚠ `subscribed` は見ない —— 購読の合図を送らない接続（Mastodon）では
  /// 出ない。
  ///
  /// ⚠ `disconnected` はつなぎ直しに失敗するたびに来るので、**最初の 1 回**の
  /// 時刻だけを持つ。
  void _trackConnection(AccountKey key, String event) {
    if (event == _eventDisconnected) {
      _disconnectedAt.putIfAbsent(key, () => _catchUpBaseline(key));
      return;
    }
    if (event != _eventConnected) return;
    // 回線は生きている。「回線側」の失敗の続きをここで終わらせる。
    streamConnectFailureReporter.noteConnected();
    final since = _disconnectedAt.remove(key);
    // 起動して最初の接続。切れていた間が無いので、拾い直すものも無い。
    if (since == null) return;
    unawaited(_catchUp(key, since));
  }

  static const _eventConnected = 'connected';
  static const _eventDisconnected = 'disconnected';

  /// 拾い直しの取得に失敗したとき、取り直すまでの待ち (#1283)。
  @visibleForTesting
  Duration catchUpRetryDelay = const Duration(seconds: 5);

  /// 拾い直せなかった窓の起点を戻す (#1283)。
  ///
  /// ⚠ **つながっている間も起点を持つことになる**（[_disconnectedAt] の「つながって
  /// いる間は持たない」の例外）。次に切れたときは `putIfAbsent` がこの古い起点を
  /// 残すので、次のつなぎ直しで両方の窓をまとめて拾える。
  /// ⚠ 待っている間にまた切れて新しい起点が入っていたら、古いほうへ寄せる。
  /// ⚠ 窓が古くなりすぎても、出す側（[selectMissedNotifications]）が直近
  /// [kMissedNotificationWindow] より前を落とす。
  void _restoreCatchUpBaseline(AccountKey key, DateTime since) {
    if (!_subs.containsKey(key)) return;
    _disconnectedAt.update(
      key,
      (current) => current.isBefore(since) ? current : since,
      ifAbsent: () => since,
    );
  }

  /// 拾い直しで見る件数。上限（[kMissedNotificationMaxCount]）より多めに引き、
  /// 窓の外のものを落としてから絞る。
  static const _catchUpFetchLimit = 10;

  Future<void> _catchUp(AccountKey key, DateTime disconnectedAt) async {
    final account = _ref
        .read(accountManagerProvider)
        .accounts
        .where((a) => a.key == key)
        .firstOrNull;
    final adapter = account?.adapter;
    if (account == null || adapter is! NotificationSupport) return;
    List<Notification>? fetched;
    // ⚠ つなぎ直した直後は回線が不安定で、ここが落ちやすい。起点は `connected`
    // で消してあるので、何もしないとこの切断の窓がまるごと捨てられる (#1283)。
    // 少し待って 1 回だけ取り直し、それでも駄目なら起点を戻す。
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        fetched = (await (adapter as NotificationSupport).getNotifications(
          query: const TimelineQuery(limit: _catchUpFetchLimit),
        )).notifications;
        break;
      } catch (e) {
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'push.desktop.catchup',
            level: SentryLevel.warning,
            message: e.runtimeType.toString(),
            data: {'attempt': attempt + 1},
          ),
        );
        if (attempt > 0) break;
        await Future<void>.delayed(catchUpRetryDelay);
        // 待っている間にログアウトされた。
        if (!_subs.containsKey(key)) return;
        // 待っている間にまた切れた。次のつなぎ直しが拾うので、ここでは引かない。
        if (_disconnectedAt.containsKey(key)) break;
      }
    }
    if (fetched == null) {
      // 拾い直しは上積みで、通知の一覧には載っている。ここでは出さずに、次に
      // つなぎ直したときにこの窓も一緒に拾えるよう、起点を戻しておく。
      _restoreCatchUpBaseline(key, disconnectedAt);
      return;
    }
    // ⚠ 引いている間にログアウトされていたら出さない。
    if (!_subs.containsKey(key)) return;
    final missed = selectMissedNotifications(
      fetched,
      disconnectedAt: disconnectedAt,
      now: now(),
    );
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: 'push.desktop.catchup',
        level: SentryLevel.info,
        message: 'emit',
        data: {'fetched': fetched.length, 'missed': missed.length},
      ),
    );
    for (final n in missed) {
      // ⚠ 重複は [_emit] が落とす（つなぎ直した直後に接続からも同じ通知が
      // 流れてくることがある・ネイティブのプッシュが先に出していることもある）。
      await _emit(account, n);
    }
  }

  /// お知らせイベントを受けたら、アプリ内のお知らせ一覧も取り直す (#888)。
  ///
  /// デスクトップは前面に居続けるためライフサイクル復帰の機会が無く、これが
  /// 「アカウントを切り替えないと新しいお知らせが出ない」問題の主経路になる。
  /// 一覧は表示中アカウントのものなので、アクティブ垢のイベントだけ反映する
  /// （他アカウント宛ては OS 通知だけ出て一覧は触らない）。
  void _refreshAnnouncementsIfNeeded(Account account, Notification n) {
    if (n.type != NotificationType.announcement) return;
    if (_ref.read(currentAccountProvider)?.key != account.key) return;
    // 生きているときだけ反映する (#915 → #919)。announcementProvider は
    // autoDispose なので、誰も watch していない状態で `.notifier` を read すると
    // **provider がここで新規生成され**、build() の取得と refresh() の取り直しで
    // 同じ一覧を 2 回投げて即破棄される。デスクトップでは DesktopMenuBar が
    // 未読数を watch しているため通常は生きているが、それに依存する構造には
    // しない（メニューバーの構成が変われば黙って無駄打ちに戻る）。生きていない
    // 間の新着は、次に一覧を開いたときの build() が最新を取るので落ちない。
    // chat_provider の #636 と同型。
    if (!_ref.exists(announcementProvider)) return;
    unawaited(_ref.read(announcementProvider.notifier).refresh());
  }

  Future<void> _emit(Account account, Notification n) async {
    // NSE (#673) が stamp する ID と同じキー空間 (`username@host|id`) の
    // 横断 dedup キー (#674)。relay の account 表現に合わせる。組み立ては
    // native の `capsicum::NotificationTagKey` と揃える [notificationTagKey] を
    // 通す（手書きにすると片方だけ書式が変わっても Dart テストは緑のまま・#960）。
    final relayKey = notificationTagKey(
      account: '${account.key.username}@${account.key.host}',
      notificationId: n.id,
    );
    if (_nativeShownKeys.contains(relayKey)) {
      // APNs 先着で OS 通知は表示済み。WebSocket 側は出さない。
      debugPrint(
        'capsicum: push.desktop: skip (native shown) '
        'account=${sentrySafeAccount(account.key)} id=${n.id}',
      );
      return;
    }
    final dedupKey = '${account.key.toStorageKey()}|${n.id}';
    if (!_emittedKeys.add(dedupKey)) return; // 既出
    // 後着の APNs banner を黙殺できるよう native 側の既出集合へ伝える
    // (#674。macOS 以外では no-op)。show より先に投げ、APNs との競争窓を
    // 最小化する。
    // ⚠⚠ **フィルターで出さない通知でも先に伝える**（PR #1285 の Codex P1）。
    // 下の判定で抜けたあとに伝えていたので、WebSocket が先着すると、後から
    // 届いたネイティブのプッシュが抑止されず、伏せた投稿がバナーに出た。
    unawaited(_ref.read(notificationDedupChannelProvider).addEmitted(relayKey));
    // 配信済み generic 通知の掃除 (#673)。APNs が先着済みの逆順ケースと、
    // この後に遅れて届くケース (onRemoteArrived 側) の両方をカバーする。
    // ⚠ フィルターに当たった通知では、先に出てしまったバナーを消す役にもなる。
    _ref.read(deliveredPushCleanerProvider).recordEmitted(relayKey);
    // 通知の適用先でフィルターに当たったものは、OS 通知を出さない (#1289)。
    // ⚠ hide だけでなく warn も出さない —— Mastodon Web のデスクトップ通知と同じ
    // 線（畳むべき本文を、畳めないバナーに出さない）。一覧には warn のまま載る。
    if (notificationFilterVerdict(n) != null) {
      debugPrint(
        'capsicum: push.desktop: skip (filtered) '
        'account=${sentrySafeAccount(account.key)} id=${n.id}',
      );
      // ⚠ 「デスクトップ通知が来ない」報告に備えて breadcrumb にも残す (#1293)。
      // debugPrint だけでは、報告の前後に何が出なかったのかを追えない。
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'push.desktop.skip',
          level: SentryLevel.info,
          message: 'filtered',
          data: {'type': n.type.name},
        ),
      );
      return;
    }
    final subsystem = _ref.read(notificationSubsystemProvider);
    final display = notificationTypeDisplay(n.type);
    // 複数アカウントがログインしているときだけ宛先を明示する (単一垢では冗長)。
    final multiAccount = _ref.read(accountManagerProvider).accounts.length > 1;
    final title = _title(n, display, multiAccount ? account.key : null);
    final body = _body(n, localHost: account.key.host);
    // 本文（ユーザーコンテンツ）はログに残さない。account/id/type と有無のみ。
    debugPrint(
      'capsicum: push.desktop: emit '
      'account=${sentrySafeAccount(account.key)} '
      'id=${n.id} type=${n.type.name} '
      'hasUser=${n.user != null} hasPost=${n.post != null}',
    );
    try {
      await subsystem.show(
        // Windows のトースト Tag は flutter_local_notifications がこの id から
        // 作るため、WNS 経路 (#474) と同じ導出にして OS 側で畳ませる (#933)。
        // 導出元は dedupKey (storageKey 由来) ではなく relayKey で、native の
        // PushDisplay.account が持つ `username@host` と同じ表現であること。
        id: stableNotificationTag(relayKey),
        title: title,
        body: body,
        payload: jsonEncode({
          'account': account.key.toStorageKey(),
          'notificationId': n.id,
          'type': n.type.name,
        }),
        category: _categoryFor(n.type),
      );
    } catch (e, st) {
      // OS 通知の表示失敗 (UNUserNotificationCenter エラー等)。zone integration
      // でも拾われるが、ここで pipeline を識別する breadcrumb を残してから
      // 計装する (account 識別子・本文は載せない)。
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'push.desktop.show',
          level: SentryLevel.warning,
          message: e.runtimeType.toString(),
        ),
      );
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('push.desktop', 'show_failed');
          scope.fingerprint = ['push.desktop.show', e.runtimeType.toString()];
        },
      );
    }
  }

  // streaming 内部の parse / 接続 / 再接続枯渇を観測層へ流す (#569)。
  // timeline_provider (#586) と同型: breadcrumb は毎回、captureException は
  // throttle、reconnect 枯渇は captureMessage。account / host は載せない。
  void _onStreamParseError(Object e, StackTrace st) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: 'push.desktop.stream.parse',
        level: SentryLevel.warning,
        // 例外型のみ。生 payload は通知本文を含みうるため breadcrumb に載せない。
        message: e.runtimeType.toString(),
      ),
    );
    final now = DateTime.now();
    if (_lastParseCapture != null &&
        now.difference(_lastParseCapture!) < _captureThrottle) {
      return;
    }
    _lastParseCapture = now;
    Sentry.captureException(
      scrubException(e),
      stackTrace: st,
      withScope: (scope) {
        scope.setTag('push.desktop.stream.parse', 'failed');
        scope.fingerprint = [
          'push.desktop.stream.parse',
          e.runtimeType.toString(),
        ];
      },
    );
  }

  void _onStreamConnectError(Object e, StackTrace st, String host) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: 'push.desktop.stream.connect',
        level: SentryLevel.warning,
        message: e.runtimeType.toString(),
      ),
    );
    final now = DateTime.now();
    // ⚠ **再接続を諦めなくなった (#1249) ので、失敗が続くかぎりここへ来続ける。**
    // 連続失敗を 1 度報告したあとは間隔を広げる（トークン失効やサーバーの
    // 長期停止で、1 台から毎分 1 件が無期限に積もらないように）。
    final throttle = _reconnectExhaustedReported
        ? _captureThrottleAfterExhausted
        : _captureThrottle;
    if (_lastConnectCapture != null &&
        now.difference(_lastConnectCapture!) < throttle) {
      return;
    }
    _lastConnectCapture = now;
    // ⚠ ここの間引き（連続失敗のあとは間隔を広げる・#1249）を通ったぶんだけを、
    // アプリ全体の報告役へ渡す (#1246)。タイムライン側の失敗と同じ瞬間なら
    // 1 件にまとまる。
    streamConnectFailureReporter.report(
      category: 'push.desktop.stream.connect',
      error: e,
      stackTrace: st,
      host: host,
    );
  }

  /// 通知用の接続の節目を breadcrumb に残す (#1252)。
  ///
  /// ⚠⚠ **以前は失敗したときにしか記録が出なかった。**しかも失敗の記録は圏外の
  /// 最中に送るので届かず、release ビルドの外から「この接続は生きているのか」を
  /// 確かめる手段が無かった（#1249 の切り分けに 1 時間以上かかった）。
  /// ⚠ **イベントとしては送らない**（件数が接続の回数ぶん出る）。次に何かの
  /// Sentry イベントが出たときに、直前の接続の様子として一緒に読める。
  /// ⚠ アカウントは載せない。サーバーの host だけ（ほかの記録と同じ線）。
  void _onStreamConnectionEvent(String event, String host) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: 'push.desktop.stream',
        level: SentryLevel.info,
        message: event,
        data: {'host': host},
      ),
    );
  }

  void _onStreamReconnectExhausted() {
    // 「再接続に連続で失敗している」状態。⚠ #1249 以降は**諦めた合図ではない**
    // （試行は続く）。つながり直すと数え直すので、切断のたびに 1 件出る。
    // #588 (streaming 再接続枯渇の UI 可視化) の観測起点。host 分岐は入れない。
    _reconnectExhaustedReported = true;
    Sentry.captureMessage(
      'push.desktop.stream.reconnect_exhausted',
      level: SentryLevel.warning,
      withScope: (scope) {
        scope.setTag('push.desktop.stream', 'reconnect_exhausted');
        scope.fingerprint = ['push.desktop.stream.reconnect_exhausted'];
      },
    );
  }

  String _title(
    Notification n,
    NotificationTypeDisplay display,
    AccountKey? recipient,
  ) {
    final base = _baseTitle(n, display);
    if (recipient == null) return base;
    // 宛先アカウントを末尾に添える (複数垢の区別用)。
    return '$base (@${recipient.username}@${recipient.host})';
  }

  String _baseTitle(Notification n, NotificationTypeDisplay display) {
    if (n.type == NotificationType.announcement) {
      final title = n.announcement?.title;
      return (title != null && title.isNotEmpty) ? title : display.label;
    }
    final name = n.user?.displayName ?? n.user?.username;
    if (name != null && name.isNotEmpty) return '${display.label} · $name';
    return display.label;
  }

  String _body(Notification n, {required String localHost}) {
    if (n.type == NotificationType.announcement) {
      return _truncate(
        _plain(
          n.announcement?.content,
          isHtml: n.announcement?.isHtml ?? false,
        ),
      );
    }
    final post = n.post;
    if (post != null) {
      // CW 付きは見出しだけを出す (#1282)。畳まれているはずの本文を、バナーと
      // 通知センターに出さない。Mastodon のサーバーがモバイル向けのプッシュで
      // 作る本文（`spoiler_text` があればそれだけ）と同じ線で、Misskey の
      // プッシュ（`PushMessageDispatcher` と各 OS の通知拡張）も揃えてある。
      // ⚠ 見出しが空の CW（Misskey）は、空のまま出すと本文へ落ちるので固定の
      // 文言にする。
      final cw = post.spoilerText;
      if (cw != null) {
        final heading = cw.trim();
        return _truncate(
          heading.isEmpty ? contentWarningFallbackLabel : heading,
        );
      }
      final text = _plain(post.content, isHtml: post.isHtml);
      if (text.isNotEmpty) return _truncate(text);
    }
    final reaction = n.reaction;
    if (reaction != null && reaction.isNotEmpty) return reaction;
    // 関係の切断・モデレーション警告 (#1084)。user を持たないので、何が
    // 起きたかを本文にする（空だとタイトルの種別名しか出ない）。
    final moderation = moderationNotificationText(n, localHost: localHost);
    if (moderation != null) return _truncate(moderation);
    return n.user?.displayName ?? n.user?.username ?? '';
  }

  /// 本文を表示用のプレーンテキストに均す。HTML (Mastodon) は [stripHtml] で
  /// タグを除去。MFM (Misskey) はそのまま (記法が多少残るが通知プレビュー
  /// 用途では許容)。
  String _plain(String? content, {required bool isHtml}) {
    if (content == null || content.isEmpty) return '';
    final text = isHtml ? stripHtml(content) : content;
    return text.trim();
  }

  String _truncate(String text) => text.length <= _maxBodyLength
      ? text
      : '${text.substring(0, _maxBodyLength)}…';

  NotificationCategory _categoryFor(NotificationType type) {
    switch (type) {
      case NotificationType.mention:
        return NotificationCategory.mention;
      case NotificationType.chat:
        return NotificationCategory.dm;
      default:
        return NotificationCategory.message;
    }
  }

  void dispose() {
    for (final sub in _subs.values) {
      sub.cancel();
    }
    _subs.clear();
  }
}

/// 起動時に main.dart (desktop) から read して常駐させる。Provider が alive な
/// 限り [DesktopNotificationDispatcher.start] の listen が生きる。
final desktopNotificationDispatcherProvider =
    Provider<DesktopNotificationDispatcher>((ref) {
      final dispatcher = DesktopNotificationDispatcher(ref);
      ref.onDispose(dispatcher.dispose);
      dispatcher.start();
      return dispatcher;
    });

/// つなぎ直したあとに OS 通知として出す、切れていた間の通知の上限 (#1261)。
///
/// 狙いは Wi-Fi の切り替えのような**短い切断**の間に届いた通知を見落とさない
/// こと。⚠⚠ **上限なしで全部出すことはしない**（2026-10-10 pooza）。スリープ
/// 明けに数時間ぶんのバナーがまとめて出る形になる。超えたぶんは出さず、アプリ内の
/// 通知一覧に任せる。
const int kMissedNotificationMaxCount = 3;

/// 拾い直す時間の幅。これより前に届いたものは、切れていた間のものでも出さない。
const Duration kMissedNotificationWindow = Duration(minutes: 10);

/// 無音で切れた回線を検知するまでに掛かりうる長さ。通知用の接続の ping 間隔
/// （60 秒）の 2 回ぶん。
const Duration kSilentDisconnectAllowance = Duration(minutes: 2);

/// 端末とサーバーの時計のずれを吸う幅。切れた時刻の少し前から拾う。
/// ⚠ 広げたぶん、切れる直前に接続から受けた通知も入ってくるが、そちらは出す側の
/// 重複の除去で落ちる。
const Duration _clockSkewAllowance = Duration(seconds: 5);

/// [fetched]（直近の通知）のうち、切れていた間に届いたものを古い順で返す (#1261)。
///
/// - [disconnectedAt] より後（時計のずれぶんは手前から）に届いたもの
/// - ただし [now] から [kMissedNotificationWindow] より前のものは出さない
/// - 多ければ**新しいほうから** [kMissedNotificationMaxCount] 件
///
/// ⚠ **基準は id ではなく時刻。**「切れる前に最後に受けた通知の id」を基準に
/// すると、起動してからまだ 1 件も受けていない接続では基準が無く、拾い直せない。
List<Notification> selectMissedNotifications(
  List<Notification> fetched, {
  required DateTime disconnectedAt,
  required DateTime now,
}) {
  final byDisconnect = disconnectedAt.subtract(_clockSkewAllowance);
  final byWindow = now.subtract(kMissedNotificationWindow);
  final from = byDisconnect.isAfter(byWindow) ? byDisconnect : byWindow;
  final missed = fetched.where((n) => n.createdAt.isAfter(from)).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return missed.length <= kMissedNotificationMaxCount
      ? missed
      : missed.sublist(missed.length - kMissedNotificationMaxCount);
}
