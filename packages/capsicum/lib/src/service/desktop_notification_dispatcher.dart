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
import '../provider/platform_providers.dart';
import '../ui/util/notification_type_display.dart';
import '../ui/widget/content_parser.dart';
import '../util/exception_scrub.dart';
import 'delivered_push_cleaner.dart';
import 'notification_dedup_channel.dart';

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
  final Set<String> _emittedKeys = {};

  /// APNs 先着で native 側 (macOS NotificationDedupPlugin) が表示済みの
  /// `username@host|notificationId` キー (#674)。[NotificationDedupChannel] の
  /// onRemotePresented で流入し、同じ通知の WebSocket 側 emit をスキップする。
  final Set<String> _nativeShownKeys = {};
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

  /// ログインアカウントの変化を listen し、購読集合を合わせる。
  /// desktop 以外では何もしない。
  void start() {
    if (!isDesktop) return;
    // APNs 先着分の逆方向 dedup (#674)。macOS 以外では channel が no-op。
    _ref.read(notificationDedupChannelProvider).onRemotePresented = (key) {
      if (_nativeShownKeys.length >= _maxTrackedKeys) {
        _nativeShownKeys.clear();
      }
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
        '(account=${account.key.toStorageKey()} adapter=${adapter.runtimeType})',
      );
      _subs[account.key] = (adapter as NotificationStreamSupport)
          .streamNotifications(
            onParseError: _onStreamParseError,
            onStreamError: _onStreamConnectError,
            onReconnectExhausted: _onStreamReconnectExhausted,
          )
          .listen(
            (n) => _emit(account, n),
            // ストリーム側の error は streaming 内 reconnect で吸収済み。
            // ここに届くのは controller close 等なので握りつぶす。
            onError: (_, _) {},
          );
    }
    final removed = _subs.keys.where((key) => !live.contains(key)).toList();
    for (final key in removed) {
      _subs.remove(key)?.cancel();
      debugPrint(
        'capsicum: push.desktop: unsubscribed '
        '(account=${key.toStorageKey()})',
      );
    }
  }

  Future<void> _emit(Account account, Notification n) async {
    // NSE (#673) が stamp する ID と同じキー空間 (`username@host|id`) の
    // 横断 dedup キー (#674)。relay の account 表現に合わせる。
    final relayKey = '${account.key.username}@${account.key.host}|${n.id}';
    if (_nativeShownKeys.contains(relayKey)) {
      // APNs 先着で OS 通知は表示済み。WebSocket 側は出さない。
      debugPrint(
        'capsicum: push.desktop: skip (native shown) '
        'account=${account.key.toStorageKey()} id=${n.id}',
      );
      return;
    }
    final dedupKey = '${account.key.toStorageKey()}|${n.id}';
    if (!_emittedKeys.add(dedupKey)) return; // 既出
    if (_emittedKeys.length > _maxTrackedKeys) {
      _emittedKeys
        ..clear()
        ..add(dedupKey);
    }
    // 後着の APNs banner を黙殺できるよう native 側の既出集合へ伝える
    // (#674。macOS 以外では no-op)。show より先に投げ、APNs との競争窓を
    // 最小化する。
    unawaited(_ref.read(notificationDedupChannelProvider).addEmitted(relayKey));
    // 配信済み generic 通知の掃除 (#673)。APNs が先着済みの逆順ケースと、
    // この後に遅れて届くケース (onRemoteArrived 側) の両方をカバーする。
    _ref.read(deliveredPushCleanerProvider).recordEmitted(relayKey);
    final subsystem = _ref.read(notificationSubsystemProvider);
    final display = notificationTypeDisplay(n.type);
    // 複数アカウントがログインしているときだけ宛先を明示する (単一垢では冗長)。
    final multiAccount = _ref.read(accountManagerProvider).accounts.length > 1;
    final title = _title(n, display, multiAccount ? account.key : null);
    final body = _body(n);
    // 本文（ユーザーコンテンツ）はログに残さない。account/id/type と有無のみ。
    debugPrint(
      'capsicum: push.desktop: emit account=${account.key.toStorageKey()} '
      'id=${n.id} type=${n.type.name} '
      'hasUser=${n.user != null} hasPost=${n.post != null}',
    );
    try {
      await subsystem.show(
        id: dedupKey.hashCode & 0x7FFFFFFF,
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

  void _onStreamConnectError(Object e, StackTrace st) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: 'push.desktop.stream.connect',
        level: SentryLevel.warning,
        message: e.runtimeType.toString(),
      ),
    );
    final now = DateTime.now();
    if (_lastConnectCapture != null &&
        now.difference(_lastConnectCapture!) < _captureThrottle) {
      return;
    }
    _lastConnectCapture = now;
    Sentry.captureException(
      scrubException(e),
      stackTrace: st,
      withScope: (scope) {
        scope.setTag('push.desktop.stream.connect', 'failed');
        scope.fingerprint = [
          'push.desktop.stream.connect',
          e.runtimeType.toString(),
        ];
      },
    );
  }

  void _onStreamReconnectExhausted() {
    // 無言で「起動中も通知が来なくなった」状態。#588 (streaming 再接続枯渇の
    // UI 可視化) の観測起点。host 分岐は入れない。
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

  String _body(Notification n) {
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
      final text = _plain(post.content, isHtml: post.isHtml);
      if (text.isNotEmpty) return _truncate(text);
    }
    final reaction = n.reaction;
    if (reaction != null && reaction.isNotEmpty) return reaction;
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
