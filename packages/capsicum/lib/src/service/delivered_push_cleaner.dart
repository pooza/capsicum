import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_dedup_channel.dart';
import 'push_message_dispatcher.dart';
import 'web_push_decryptor.dart';

/// macOS の通知センターに残った generic 文面の APNs 通知を後始末する (#673)。
///
/// macOS は NSE に didReceive を渡さず約 2 秒で kill するため (OS 側の実装
/// 欠落。Apple Dev Forums 693011 等)、APNs 通知は常に relay のフォールバック
/// 文面「{account} に通知があります」のまま配信される。アプリ起動中は同じ
/// イベントを WebSocket 経路 (#569) がリッチ文面で表示するので、APNs 側は
/// 丸ごと余剰 = 重複 (#674) になる。
///
/// 本 service は main app が復号鍵を持つことを利用して、配信済み APNs 通知の
/// 暗号化 body を復号 → notificationId を特定 → WebSocket 側の既出キー
/// (`username@host|id`) と一致したものだけを通知センターから削除する。
/// 一致しないもの (WebSocket が落ちていた間に届いた通知等) は、ユーザーへの
/// 唯一の到達経路かもしれないため削除しない。
///
/// 掃除のトリガは 2 つ:
/// - [NotificationDedupChannel.onRemoteArrived]: AppDelegate の
///   didReceiveRemoteNotification 由来。APNs はイベントから数分遅れて届く
///   ことがある (2026-06-12 実測で 2〜7 分) ため、これが主経路。
/// - [recordEmitted]: WebSocket 側の emit 直後。APNs が先着していた逆順
///   ケースを拾う。
///
/// アプリ非起動時に届いた generic 通知は次回起動後の emit / remote 到着を
/// 契機に掃除されうるが、既出キーが揮発しているため基本は残る。これは
/// 「未読の事実を伝える通知」として正しい挙動なので追わない。
class DeliveredPushCleaner {
  DeliveredPushCleaner(
    this._channel, {
    @visibleForTesting bool? supportedOverride,
  }) : _supportedOverride = supportedOverride;

  final NotificationDedupChannel _channel;

  /// テストはホスト OS に依存せず macOS 経路を通すため override する。
  final bool? _supportedOverride;

  /// WebSocket 側で表示済みの `username@host|id` キー。
  /// DesktopNotificationDispatcher / NotificationDedupPlugin と同じ上限運用
  /// (超えたら全消し。取りこぼしは「重複が残る」だけで安全側)。
  final Set<String> _emittedKeys = {};

  /// identifier → 解決済み relayKey (解決不能は null)。配信済み通知は削除
  /// されるまで毎 sweep 列挙されるため、復号を 1 通知 1 回に抑える。
  final Map<String, String?> _resolvedKeys = {};
  static const _maxTracked = 500;

  /// banner の配信完了 (delivered 反映) を待ってから掃除する遅延。
  static const _sweepDelay = Duration(seconds: 2);
  Timer? _pendingSweep;

  bool get _supported => _supportedOverride ?? (!kIsWeb && Platform.isMacOS);

  /// native からの APNs 到着合図を listen し始める。アプリ起動時に 1 回呼ぶ。
  void start() {
    if (!_supported) return;
    _channel.onRemoteArrived = _scheduleSweep;
  }

  /// WebSocket 側で表示した通知のキーを記録し、掃除を予約する。
  /// [DesktopNotificationDispatcher] が emit 時に呼ぶ。
  void recordEmitted(String relayKey) {
    if (!_supported) return;
    if (_emittedKeys.length >= _maxTracked) {
      _emittedKeys.clear();
    }
    _emittedKeys.add(relayKey);
    _scheduleSweep();
  }

  void _scheduleSweep() {
    _pendingSweep?.cancel();
    _pendingSweep = Timer(_sweepDelay, () => unawaited(sweep()));
  }

  /// 配信済み APNs 通知を列挙し、既出キーと一致するものを削除する。
  @visibleForTesting
  Future<void> sweep() async {
    if (_emittedKeys.isEmpty) return;
    final delivered = await _channel.getDeliveredRemotes();
    if (delivered.isEmpty) return;
    final removable = <String>[];
    for (final notification in delivered) {
      final key = await _relayKeyFor(notification);
      if (key != null && _emittedKeys.contains(key)) {
        removable.add(notification.identifier);
      }
    }
    if (removable.isEmpty) return;
    // 件数のみログする (identifier / account はユーザー識別子を含むため
    // 出さない)。
    debugPrint(
      'capsicum: push.cleaner: removing ${removable.length} '
      'duplicate generic notification(s)',
    );
    await _channel.removeDelivered(removable);
  }

  Future<String?> _relayKeyFor(DeliveredRemoteNotification notification) async {
    if (_resolvedKeys.containsKey(notification.identifier)) {
      return _resolvedKeys[notification.identifier];
    }
    final key = await _resolve(notification);
    if (_resolvedKeys.length >= _maxTracked) {
      _resolvedKeys.clear();
    }
    _resolvedKeys[notification.identifier] = key;
    return key;
  }

  /// 通知 1 件の `username@host|id` キーを解決する。復号失敗・鍵不在・
  /// announcement (#477。body を持たない) 等の解決不能は null = 削除対象外。
  Future<String?> _resolve(DeliveredRemoteNotification notification) async {
    // NSE の stamp があれば復号不要 (OS 側が直った将来ケース)。
    final stamped = notification.stampedId;
    if (stamped != null && stamped.isNotEmpty) {
      return '${notification.account}|$stamped';
    }
    final bodyB64 = notification.body;
    if (bodyB64 == null || notification.encoding != 'aes128gcm') {
      return null;
    }
    final keys = await PushMessageDispatcher.findKeys(notification.account);
    if (keys == null) return null;
    try {
      final plaintext = WebPushDecryptor.decryptAes128gcm(
        body: base64Url.decode(base64Url.normalize(bodyB64)),
        uaPrivateKeyD: base64Url.decode(
          base64Url.normalize(keys.privateKeyBase64),
        ),
        uaPublicKey: base64Url.decode(base64Url.normalize(keys.p256dh)),
        authSecret: base64Url.decode(base64Url.normalize(keys.auth)),
      );
      final id = PushMessageDispatcher.parsePayload(plaintext)?.notificationId;
      if (id == null) return null;
      return '${notification.account}|$id';
    } catch (_) {
      // 復号・パース失敗。FCM 実走経路 (PushMessageDispatcher) と違い表示は
      // 既に済んでいるので、ここでは観測せず削除対象外にするだけ。
      return null;
    }
  }

  void dispose() {
    _pendingSweep?.cancel();
  }
}

/// [DesktopNotificationDispatcher.start] から read して常駐させる。
final deliveredPushCleanerProvider = Provider<DeliveredPushCleaner>((ref) {
  final cleaner = DeliveredPushCleaner(
    ref.read(notificationDedupChannelProvider),
  );
  ref.onDispose(cleaner.dispose);
  cleaner.start();
  return cleaner;
});
