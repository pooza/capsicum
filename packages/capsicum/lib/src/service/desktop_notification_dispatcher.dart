import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/notification_subsystem/notification_subsystem.dart';
import '../platform/platform_info.dart';
import '../provider/account_manager_provider.dart';
import '../provider/platform_providers.dart';
import '../ui/util/notification_type_display.dart';
import '../ui/widget/content_parser.dart';

/// デスクトップ 3 OS (macOS / Linux / Windows) で、アクティブアカウントの
/// WebSocket 通知ストリーミング ([NotificationStreamSupport]) を OS ローカル
/// 通知 ([NotificationSubsystem]) に橋渡しする service (#569)。
///
/// アプリ起動中限定の通知配信。ネイティブ push (APNs #468 / WNS #474) とは
/// `notification.id` ベースの dedup で併存する。設計は
/// docs/desktop-notification-design.md を参照。
class DesktopNotificationDispatcher {
  DesktopNotificationDispatcher(this._ref);

  final Ref _ref;
  StreamSubscription<Notification>? _sub;

  /// セッション内 dedup。将来 native push と二重受信する通知を取りこぼさず
  /// 1 表示に抑える。アカウント切替時にクリア。
  final Set<String> _emittedIds = {};
  static const _maxTrackedIds = 500;

  /// OS 通知本文の上限。OS 側でも truncate されるが念のため client 側でも切る。
  static const _maxBodyLength = 200;

  /// アクティブアダプターの変化を listen し、通知ストリーミングを購読し直す。
  /// desktop 以外では何もしない。
  void start() {
    if (!isDesktop) return;
    _ref.listen<DecentralizedBackendAdapter?>(currentAdapterProvider, (
      prev,
      next,
    ) {
      // 旧アダプターの購読を切る。broadcast controller の onCancel で
      // 旧 streaming も dispose される。
      _sub?.cancel();
      _sub = null;
      _emittedIds.clear();
      if (next is NotificationStreamSupport) {
        _sub = (next as NotificationStreamSupport).streamNotifications().listen(
          _emit,
          // ストリーム側の error は streaming 内 reconnect で吸収済み。
          // ここに届くのは controller close 等なので握りつぶす。
          onError: (_, _) {},
        );
      }
    }, fireImmediately: true);
  }

  Future<void> _emit(Notification n) async {
    if (!_emittedIds.add(n.id)) return; // 既出 (native push 経由含む)
    if (_emittedIds.length > _maxTrackedIds) {
      _emittedIds
        ..clear()
        ..add(n.id);
    }
    final subsystem = _ref.read(notificationSubsystemProvider);
    final display = notificationTypeDisplay(n.type);
    await subsystem.show(
      id: n.id.hashCode & 0x7FFFFFFF,
      title: _title(n, display),
      body: _body(n),
      payload: jsonEncode({'notificationId': n.id, 'type': n.type.name}),
      category: _categoryFor(n.type),
    );
  }

  String _title(Notification n, NotificationTypeDisplay display) {
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
    _sub?.cancel();
    _sub = null;
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
