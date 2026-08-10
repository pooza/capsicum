import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 起動中二重通知 dedup (#674) の Dart 側終端。
///
/// macOS ネイティブの NotificationDedupPlugin (UNUserNotificationCenter
/// delegate proxy) と双方向に「既出キー」を共有する:
///
/// - Dart → native: WebSocket 経由 (#569) で表示する通知のキーを
///   [addEmitted] で伝える → 後着の APNs banner を native 側が黙殺
/// - native → Dart: APNs が先着して表示済みのキーを [onRemotePresented] で
///   受ける → [DesktopNotificationDispatcher] が同じ通知の emit をスキップ
///
/// キー形式は relay / NSE の account 表現に合わせた
/// `username@host|notificationId`（NSE が復号 payload から stamp する ID と
/// 同じ ID 空間。docs/desktop-notification-design.md §5）。
///
/// 配線されているのは **macOS (#468) と Windows (#945)** で、それ以外では何も
/// しない。
///
/// Windows は当初「両経路のトースト Tag を同じ導出に揃えて OS 側に畳ませる」
/// 方式だった (#933。`notification_tag.dart`)。bg task が別プロセスで動くため
/// この受け渡しに乗せられない、という理由だったが、
///
/// - **実機で畳まれなかった** (#945。Tag / Group / AUMID はいずれも一致して
///   いるのに 2 通出る)
/// - 畳めたとしても 2 通目のトースト自体は作られるので**通知音の重複が残る**
/// - **起動中**の WNS 受信は bg task ではなく本体プロセス (`wns_push.cpp` の
///   in-process 受信) が担うので、そもそもプロセスを跨がない
///
/// の 3 点から、macOS と同じ「先に出した方が勝つ」方式へ寄せた。native 側の
/// 終端は `windows/runner/notification_dedup.{h,cpp}`。Tag を揃える #933 の
/// 実装は、dedup を取りこぼしたときの二段目の受け皿として残してある。
///
/// なお **アプリ完全終了中の bg task はこの dedup を通らない**。別プロセスで
/// 動くうえ、そのとき WebSocket 経路は存在しないので競合しない。
class NotificationDedupChannel {
  NotificationDedupChannel({@visibleForTesting MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('net.shrieker.capsicum/notification_dedup');

  final MethodChannel _channel;

  /// APNs 先着で native 側が表示済みのキーを受けるコールバック。
  /// [DesktopNotificationDispatcher] が配線する。
  void Function(String key)? onRemotePresented;

  /// アプリ起動中に APNs が届いた合図 (AppDelegate の
  /// didReceiveRemoteNotification 由来)。macOS は NSE (#673) が機能しないため
  /// generic 文面の banner がこの直後に配信される。[DeliveredPushCleaner] が
  /// 掃除のトリガとして配線する。
  void Function()? onRemoteArrived;

  /// 双方向 dedup（[start] / [addEmitted] / [onRemotePresented]）が使えるか。
  bool get _supported => !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  /// NSE 由来の配信済み通知の掃除 (#673) が使えるか。**macOS 専用**で、Windows
  /// には NSE も通知センターの列挙 API も無い（native 側は NotImplemented）。
  bool get _deliveredCleanupSupported => !kIsWeb && Platform.isMacOS;

  /// native からの逆方向通知を listen し始める。アプリ起動時に 1 回呼ぶ。
  void start() {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRemotePresented':
          final key = call.arguments as String?;
          if (key != null) onRemotePresented?.call(key);
        case 'onRemoteArrived':
          onRemoteArrived?.call();
      }
    });
  }

  /// WebSocket 側で表示する通知のキーを native の既出集合へ伝える。
  Future<void> addEmitted(String key) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('addEmitted', key);
    } on PlatformException {
      // proxy 未 install (FLN delegate 不在等の想定外) や呼び出し失敗。
      // dedup は成立しないが、設計上「多重表示の方が落とすより安全」に倒す。
    } on MissingPluginException {
      // 同上。native 側が channel を張れなかったケース。
    }
  }

  /// 配信済み通知のうち APNs remote 由来のものを取得する (#673 掃除用)。
  /// 失敗時 (proxy 未 install 等) は空リスト = 掃除対象なし扱い。
  Future<List<DeliveredRemoteNotification>> getDeliveredRemotes() async {
    if (!_deliveredCleanupSupported) return const [];
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'getDeliveredRemotes',
      );
      if (raw == null) return const [];
      return [
        for (final entry in raw)
          if (entry['identifier'] is String && entry['account'] is String)
            DeliveredRemoteNotification(
              identifier: entry['identifier']! as String,
              account: entry['account']! as String,
              body: entry['body'] as String?,
              encoding: entry['encoding'] as String?,
              stampedId: entry['stampedId'] as String?,
            ),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// 配信済み通知を identifier 指定で通知センターから削除する (#673 掃除用)。
  Future<void> removeDelivered(List<String> identifiers) async {
    if (!_deliveredCleanupSupported || identifiers.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('removeDelivered', identifiers);
    } on PlatformException {
      // 削除失敗は「重複が残る」だけなので握りつぶす。
    } on MissingPluginException {
      // 同上。
    }
  }
}

/// 通知センターに配信済みの APNs remote 通知 1 件分 (#673 掃除用)。
/// native 側 NotificationDedupPlugin.collectDeliveredRemotes の出力に対応する。
class DeliveredRemoteNotification {
  /// UNNotificationRequest.identifier。削除指定に使う。
  final String identifier;

  /// relay が userInfo に載せる `username@host`。
  final String account;

  /// Web Push 暗号化ペイロード (base64url)。announcement push (#477) には無い。
  final String? body;

  /// `aes128gcm` 等。[body] とセットで復号可否の判定に使う。
  final String? encoding;

  /// NSE が stamp した通知 ID。macOS では NSE が機能しない (#673) ため通常
  /// null だが、OS 側が直った場合は復号せずこれで突き合わせる。
  final String? stampedId;

  const DeliveredRemoteNotification({
    required this.identifier,
    required this.account,
    this.body,
    this.encoding,
    this.stampedId,
  });
}

final notificationDedupChannelProvider = Provider<NotificationDedupChannel>(
  (_) => NotificationDedupChannel()..start(),
);
