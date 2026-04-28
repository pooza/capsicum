import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../ui/util/notification_type_display.dart';
import 'notification_init.dart';
import 'push_failure_recorder.dart';
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
    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    int elapsed() => DateTime.now().millisecondsSinceEpoch - startedAtMs;
    final host = _hostFromAccount(account);

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
      await PushFailureRecorder.record(
        PushFailureRecorder.codeNoKeys,
        host: host,
        encoding: encoding,
        elapsedMs: elapsed(),
      );
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
      if (parsed == null) {
        await PushFailureRecorder.record(
          PushFailureRecorder.codeParseFailed,
          host: host,
          encoding: encoding,
          elapsedMs: elapsed(),
        );
      }
      return parsed;
    } catch (e) {
      debugPrint('capsicum: push.dispatcher: decrypt failed: $e');
      await PushFailureRecorder.record(
        PushFailureRecorder.codeDecryptFailed,
        host: host,
        encoding: encoding,
        elapsedMs: elapsed(),
      );
      return null;
    }
  }

  /// `username@host` 形式のアカウント識別子から host 部分を取り出す。
  /// 取得できない場合（`@` がない / 末尾が `@`）は `null`。
  /// NSE 側 `hostFromAccount` と同じ仕様。
  static String? _hostFromAccount(String account) {
    final at = account.lastIndexOf('@');
    if (at < 0 || at == account.length - 1) return null;
    return account.substring(at + 1);
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
  /// という JSON。
  /// Misskey は `{type: 'notification', body: {type, user, note, ...}, ...}`
  /// と構造が異なるため、両形式を個別にサポートする。
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

      // Mastodon: top-level に title / body / notification_type
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

      // Misskey: {type: 'notification', body: { type, user, note, reaction, ... }}
      // 他にも 'readAllNotifications'（UI 同期用、通知表示しない）や
      // 'unreadAntennaNote' 等がある。通知として出すのは 'notification' のみ。
      if (json['type'] == 'notification') {
        final inner = json['body'];
        if (inner is Map<String, dynamic>) {
          return DecryptedPushContent(
            title: null,
            body: _synthesizeMisskeyBody(inner),
            type: inner['type'] as String?,
          );
        }
      }
      return null;
    } catch (e) {
      debugPrint('capsicum: push.dispatcher: parse failed: $e');
      return null;
    }
  }

  /// Misskey の通知オブジェクトから通知本文を合成する。Mastodon が
  /// サーバー側で `body` に整形済み文字列を入れてくるのに対し、Misskey は
  /// 構造化されたオブジェクトで送ってくるため、クライアント側で表示用に
  /// 文章化する必要がある。
  ///
  /// 優先順位:
  /// 1. `note.text` がある種別（mention / reply / quote / renote） → 投稿本文
  /// 2. reaction → `@user が {reaction} でリアクション`
  /// 3. follow → `@user にフォローされました`
  /// 4. それ以外 → 送信者の表示名のみ
  static String? _synthesizeMisskeyBody(Map<String, dynamic> body) {
    final note = body['note'] is Map<String, dynamic>
        ? body['note'] as Map<String, dynamic>
        : null;
    final user = body['user'] is Map<String, dynamic>
        ? body['user'] as Map<String, dynamic>
        : null;
    final reaction = body['reaction'] as String?;
    final type = body['type'] as String?;

    final noteText = note?['text'] as String?;
    if (noteText != null && noteText.isNotEmpty) {
      return noteText;
    }

    final displayName = (user?['name'] as String?)?.trim();
    final username = user?['username'] as String?;
    final actor = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : (username != null ? '@$username' : null);

    if (type == 'reaction' && reaction != null) {
      return actor != null ? '$actor が $reaction でリアクション' : reaction;
    }
    if (type == 'follow' && actor != null) {
      return '$actor にフォローされました';
    }
    return actor;
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
    // 32bit に丸めて ID にする。ms 精度で取る（秒精度だと同一秒内に来た通知が
    // 同 ID で上書きされる）。
    final id = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
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
