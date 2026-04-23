import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../ui/util/notification_type_display.dart';
import 'notification_init.dart';
import 'push_key_store.dart';
import 'web_push_decryptor.dart';

/// FCM から受信した RemoteMessage を復号し、flutter_local_notifications 経由で
/// 通知を表示する。
///
/// 呼び出し元:
/// - フォアグラウンド: [FirebaseMessaging.onMessage] → main.dart の listener
/// - バックグラウンド / キル: main.dart の top-level
///   `_firebaseBackgroundMessageHandler` から (#336 Phase 3)
///
/// リレーは `notification` ブロックを落として data-only で送るため、Android は
/// どの状態でもこのディスパッチャを経由して復号 + 通知表示が走る。
class PushMessageDispatcher {
  static const _channelId = 'capsicum_push';
  static const _channelName = 'プッシュ通知';

  /// FCM メッセージを処理して通知を表示する。復号失敗 / 鍵不在時は fallback
  /// 文言 (`{account} に通知があります`) で表示し、完全に無応答にはしない。
  ///
  /// [reblogLabelResolver] は通知宛先アカウントごとの「ブースト/リノート」
  /// ラベルを返す。モロヘイヤの `reblog_label` を反映したいため、現在選択
  /// アカウントではなく宛先アカウント単位で解決する必要がある。
  /// 未指定時は "ブースト"。
  ///
  /// [postLabelResolver] は投稿ラベル（Mastodon カスタム "トゥート" 等）。
  /// 未指定時は "投稿"。
  ///
  /// resolvers は [FutureOr] を返してよい。フォアグラウンド経路は Riverpod
  /// から同期的に返せるが、バックグラウンド isolate では [SharedPreferences]
  /// 経由の非同期読み出しになるため。
  static Future<void> dispatch(
    RemoteMessage message, {
    FutureOr<String> Function(String account)? reblogLabelResolver,
    FutureOr<String> Function(String account)? postLabelResolver,
  }) async {
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
      // 用語統一: Mastodon サーバー生成 title の「返信」等は UI と表記揺れ
      // するので、notification_type から capsicum 規定のラベルを作る。
      // type が取れないケースのみサーバー title を fallback に使う。
      if (decrypted.type != null) {
        final reblogLabel = reblogLabelResolver != null
            ? await reblogLabelResolver(account)
            : 'ブースト';
        final postLabel = postLabelResolver != null
            ? await postLabelResolver(account)
            : '投稿';
        title = notificationTypeDisplay(
          notificationTypeFromString(decrypted.type),
          reblogLabel: reblogLabel,
          postLabel: postLabel,
        ).label;
      } else if (decrypted.title != null && decrypted.title!.isNotEmpty) {
        title = decrypted.title!;
      }
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
      debugPrint(
        'capsicum: push.dispatcher: skipped decrypt '
        '(body=${bodyB64 != null}, encoding=$encoding)',
      );
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
      debugPrint(
        'capsicum: push.dispatcher: decrypt ok, ${plaintext.length} bytes',
      );
      final parsed = parsePayload(plaintext);
      debugPrint(
        'capsicum: push.dispatcher: parsed=${parsed != null} '
        'titleLen=${parsed?.title?.length} bodyLen=${parsed?.body?.length}',
      );
      return parsed;
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
  /// 異なる。本実装は Mastodon 形式のみサポート。Misskey ネイティブ形式への
  /// 対応は到着するペイロードの実地確認後に判断する。
  ///
  /// `public` visibility は test 用。
  @visibleForTesting
  static DecryptedPushContent? parsePayload(Uint8List plaintext) {
    try {
      final text = utf8.decode(plaintext);
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) {
        debugPrint(
          'capsicum: push.dispatcher: payload not a Map (${json.runtimeType})',
        );
        return null;
      }
      debugPrint(
        'capsicum: push.dispatcher: payload keys=${json.keys.toList()}',
      );

      final mastodonTitle = json['title'];
      final mastodonBody = json['body'];
      final mastodonType = json['notification_type'];
      if (mastodonTitle is String ||
          mastodonBody is String ||
          mastodonType is String) {
        return DecryptedPushContent(
          title: mastodonTitle is String ? mastodonTitle : null,
          body: mastodonBody is String ? mastodonBody : null,
          type: mastodonType is String ? mastodonType : null,
        );
      }
      return null;
    } catch (e) {
      debugPrint('capsicum: push.dispatcher: parse failed: $e');
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
  /// Mastodon サーバー生成の title 文字列 (例: "@user さんから返信がありました")。
  /// capsicum の用語統一（返信→メンション等）のため、通知表示では `type` から
  /// 作る typeLabel を優先し、この文字列はそのまま使わない。
  final String? title;
  final String? body;
  final String? type;
  const DecryptedPushContent({this.title, this.body, this.type});
}
