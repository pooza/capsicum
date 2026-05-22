import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../ui/util/notification_type_display.dart';
import 'notification_init.dart';
import 'push_failure_recorder.dart';
import 'push_key_store.dart';
import 'web_push_decryptor.dart';

/// push 復号フローの途中経過を debugPrint + Sentry breadcrumb の両方に出す
/// 共通ヘルパ (#460)。後段で `captureException` が走ったときに、復号失敗
/// 直前のコンテキストが Sentry イベントに自動添付される。
void _trace(String message) {
  debugPrint('capsicum: push.dispatcher: $message');
  try {
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: 'push.dispatcher',
        level: SentryLevel.info,
        message: message,
      ),
    );
  } catch (_) {
    // Sentry 未初期化の background isolate 等で失敗しても本筋を止めない。
  }
}

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
      _trace('missing account');
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

    // タップ payload は JSON 化して type / userId も伝搬する。chat の場合は
    // タップで /chat/user/:userId に直行できるよう main.dart 側で分岐 (#440)。
    final payload = jsonEncode({
      'account': account,
      if (decrypted?.type != null) 'type': decrypted!.type,
      if (decrypted?.userId != null) 'userId': decrypted!.userId,
    });
    await _showNotification(title: title, body: body, payload: payload);
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
      _trace('skipped decrypt (body=${bodyB64 != null}, encoding=$encoding)');
      return null;
    }

    final keys = await _findKeys(account);
    if (keys == null) {
      _trace('no push keys for $account');
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
      _trace('decrypt ok, ${plaintext.length} bytes');
      final parsed = parsePayload(plaintext);
      _trace(
        'parsed=${parsed != null} '
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
      _trace('decrypt failed: $e');
      await PushFailureRecorder.record(
        PushFailureRecorder.codeDecryptFailed,
        host: host,
        encoding: encoding,
        elapsedMs: elapsed(),
        // FormatException (bodyB64 異常) や WebPushDecryptor / parsePayload
        // が投げた exception 文字列を kind 分類 (push.decrypt.kind) のために
        // recorder に流す (#436 の二次分類タグを実走経路にも適用)。
        decryptError: e.toString(),
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
        _trace('payload not a Map (${json.runtimeType})');
        return null;
      }
      _trace('payload keys=${json.keys.toList()}');

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

      // Misskey 新 chat: {type: 'newChatMessage', body: <ChatMessage>, ...} (#248)。
      // /api/i/notifications には来ない push 専用 type。body は ChatMessage そのもの
      // で fromUser / text / file を直接持つ。
      if (json['type'] == 'newChatMessage') {
        final inner = json['body'];
        if (inner is Map<String, dynamic>) {
          final fromUser = inner['fromUser'];
          final userId = fromUser is Map<String, dynamic>
              ? fromUser['id'] as String?
              : inner['fromUserId'] as String?;
          return DecryptedPushContent(
            title: null,
            body: _synthesizeMisskeyChatBody(inner),
            type: 'newChatMessage',
            userId: userId,
          );
        }
      }
      return null;
    } catch (e) {
      _trace('parse failed: $e');
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

  /// Misskey 新 chat の `newChatMessage` push payload 内の `body`
  /// (= ChatMessage そのもの) から通知本文を合成する。
  ///
  /// 形式: `<actor>: <text or 添付ラベル>`。fromUser が省略される場合は
  /// テキストのみ（送信者は notification の payload にも `userId` がいるが、
  /// 表示には文脈が薄いので省く）。
  static String? _synthesizeMisskeyChatBody(Map<String, dynamic> body) {
    final fromUser = body['fromUser'] is Map<String, dynamic>
        ? body['fromUser'] as Map<String, dynamic>
        : null;
    final text = body['text'] as String?;
    final fileMime = body['file'] is Map<String, dynamic>
        ? (body['file'] as Map<String, dynamic>)['type'] as String?
        : null;

    final displayName = (fromUser?['name'] as String?)?.trim();
    final username = fromUser?['username'] as String?;
    final actor = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : (username != null ? '@$username' : null);

    String content;
    if (text != null && text.isNotEmpty) {
      content = text;
    } else if (fileMime != null) {
      if (fileMime.startsWith('image/')) {
        content = '[画像]';
      } else if (fileMime.startsWith('video/')) {
        content = '[動画]';
      } else if (fileMime.startsWith('audio/')) {
        content = '[音声]';
      } else {
        content = '[ファイル]';
      }
    } else {
      content = '';
    }

    if (actor == null) return content.isEmpty ? null : content;
    return content.isEmpty ? actor : '$actor: $content';
  }

  static Future<void> _showNotification({
    required String title,
    required String body,
    required String payload,
  }) async {
    // 通知 ID は同時に複数通知を並べられるよう unique 化する。Mastodon の
    // notification_id があれば使いたいが、Phase 2 では簡便にタイムスタンプを
    // 32bit に丸めて ID にする。ms 精度で取る（秒精度だと同一秒内に来た通知が
    // 同 ID で上書きされる）。
    final id = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
    await notificationSubsystem.show(
      id: id,
      title: title,
      body: body,
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

  /// Misskey newChatMessage の `fromUser.id` (タップで `/chat/user/:id`
  /// に遷移する宛先解決に使う)。type=newChatMessage 以外は null (#440)。
  final String? userId;

  const DecryptedPushContent({this.title, this.body, this.type, this.userId});
}
