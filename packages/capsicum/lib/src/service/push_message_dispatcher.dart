import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_init.dart';
import 'push_key_store.dart';
import 'web_push_decryptor.dart';

/// FCM から受信した RemoteMessage を復号し、flutter_local_notifications 経由で
/// 通知を表示する。
///
/// Phase 2 (#336) 時点ではフォアグラウンドの [FirebaseMessaging.onMessage] から
/// 呼ばれることを想定。バックグラウンド対応は Phase 3 で relay 側が
/// `notification` ブロックを落とす変更と合わせて投入する。
class PushMessageDispatcher {
  static const _channelId = 'capsicum_push';
  static const _channelName = 'プッシュ通知';

  /// FCM メッセージを処理して通知を表示する。復号失敗 / 鍵不在時は fallback
  /// 文言 (`{account} に通知があります`) で表示し、完全に無応答にはしない。
  static Future<void> dispatch(RemoteMessage message) async {
    final data = message.data;
    final account = data['account'] as String?;
    if (account == null || account.isEmpty) {
      debugPrint('capsicum: push.dispatcher: missing account');
      return;
    }

    var title = 'capsicum';
    var body = '$account に通知があります';

    final decrypted = await _tryDecrypt(account, data);
    if (decrypted != null) {
      title = decrypted.title ?? title;
      if (decrypted.body != null && decrypted.body!.isNotEmpty) {
        body = decrypted.body!;
      }
    }

    await _showNotification(title: title, body: body, payload: account);
  }

  static Future<DecryptedPushContent?> _tryDecrypt(
    String account,
    Map<String, dynamic> data,
  ) async {
    final bodyB64 = data['body'] as String?;
    final encoding = data['encoding'] as String?;
    if (bodyB64 == null || encoding != 'aes128gcm') {
      return null;
    }

    final keys = await _findKeys(account);
    if (keys == null) {
      debugPrint('capsicum: push.dispatcher: no push keys for $account');
      return null;
    }

    try {
      final bodyBytes = base64Url.decode(base64Url.normalize(bodyB64));
      final plaintext = WebPushDecryptor.decryptAes128gcm(
        body: bodyBytes,
        uaPrivateKeyD: base64Url.decode(
          base64Url.normalize(keys.privateKeyBase64),
        ),
        uaPublicKey: base64Url.decode(base64Url.normalize(keys.p256dh)),
        authSecret: base64Url.decode(base64Url.normalize(keys.auth)),
      );
      return parsePayload(plaintext);
    } catch (e) {
      debugPrint('capsicum: push.dispatcher: decrypt failed: $e');
      return null;
    }
  }

  /// `account` (username@host) に紐付く PushKeys を探す。backend 種別
  /// (mastodon / misskey) がペイロードからは判別できないため、両 prefix で
  /// 順に試す。最初に見つかった方を返す。
  static Future<PushKeys?> _findKeys(String account) async {
    for (final prefix in ['mastodon', 'misskey']) {
      final storageKey = '$prefix://$account';
      final keys = await PushKeyStore.read(storageKey);
      if (keys != null) return keys;
    }
    return null;
  }

  /// 復号済み平文から title / body を抜き出す。
  ///
  /// Mastodon の Web Push ペイロードは `{title, body, notification_type, ...}`
  /// という JSON。Misskey は `{type, body: {user, note, ...}, ...}` と構造が
  /// 異なるため、Phase 2 では Mastodon 形式のみサポート。Misskey 形式は
  /// Phase 3 以降で対応する。
  ///
  /// `public` visibility は test 用。
  @visibleForTesting
  static DecryptedPushContent? parsePayload(Uint8List plaintext) {
    try {
      final text = utf8.decode(plaintext);
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;

      final mastodonTitle = json['title'];
      final mastodonBody = json['body'];
      if (mastodonTitle is String || mastodonBody is String) {
        return DecryptedPushContent(
          title: mastodonTitle is String ? mastodonTitle : null,
          body: mastodonBody is String ? mastodonBody : null,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _showNotification({
    required String title,
    required String body,
    required String payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    // 通知 ID は同時に複数通知を並べられるよう unique 化する。Mastodon の
    // notification_id があれば使いたいが、Phase 2 では簡便にタイムスタンプを
    // 32bit に丸めて ID にする。
    final id = (DateTime.now().millisecondsSinceEpoch ~/ 1000) & 0x7fffffff;
    await NotificationInit.plugin.show(
      id,
      title,
      body,
      details,
      payload: payload,
    );
  }
}

class DecryptedPushContent {
  final String? title;
  final String? body;
  const DecryptedPushContent({this.title, this.body});
}
