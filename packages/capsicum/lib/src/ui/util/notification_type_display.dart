import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

/// `NotificationType` の UI 表示情報（アイコン + ラベル）。
///
/// 中央集約することで、in-app の通知リスト・プッシュ通知・その他 UI が
/// 同じ用語を使うことを保証する。例: メンションを「返信」と表示している
/// Mastodon サーバー生成文字列は、ここで一律「メンション」に寄せる。
class NotificationTypeDisplay {
  final IconData icon;
  final String label;
  const NotificationTypeDisplay({required this.icon, required this.label});
}

/// `NotificationType` に対する表示情報を返す。
///
/// [reblogLabel] は Mastodon では「ブースト」、Misskey では「リノート」など、
/// アダプター/サーバー設定で動的に決まるため呼び出し側から注入する。
/// [postLabel] はサーバーが設定するカスタム投稿ラベル (例: 「トゥート」)。
NotificationTypeDisplay notificationTypeDisplay(
  NotificationType type, {
  String reblogLabel = 'ブースト',
  String postLabel = '投稿',
}) {
  switch (type) {
    case NotificationType.mention:
      return const NotificationTypeDisplay(
        icon: Icons.alternate_email,
        label: 'メンション',
      );
    case NotificationType.reblog:
      return NotificationTypeDisplay(icon: Icons.repeat, label: reblogLabel);
    case NotificationType.favourite:
      return const NotificationTypeDisplay(icon: Icons.star, label: 'お気に入り');
    case NotificationType.follow:
      return const NotificationTypeDisplay(
        icon: Icons.person_add,
        label: 'フォロー',
      );
    case NotificationType.followRequest:
      return const NotificationTypeDisplay(
        icon: Icons.person_add_alt,
        label: 'フォローリクエスト',
      );
    case NotificationType.reaction:
      return const NotificationTypeDisplay(
        icon: Icons.emoji_emotions,
        label: 'リアクション',
      );
    case NotificationType.poll:
      return const NotificationTypeDisplay(icon: Icons.poll, label: 'アンケート終了');
    case NotificationType.update:
      return NotificationTypeDisplay(icon: Icons.edit, label: '$postLabelを編集');
    case NotificationType.login:
      return const NotificationTypeDisplay(icon: Icons.login, label: 'ログイン');
    case NotificationType.createToken:
      return const NotificationTypeDisplay(
        icon: Icons.key,
        label: 'アクセストークン作成',
      );
    case NotificationType.other:
      return const NotificationTypeDisplay(
        icon: Icons.notifications,
        label: '通知',
      );
  }
}

/// Mastodon Web Push ペイロードや API レスポンスの `notification_type` 文字列を
/// [NotificationType] enum に変換する。未知の文字列は [NotificationType.other]。
NotificationType notificationTypeFromString(String? raw) {
  switch (raw) {
    case 'mention':
      return NotificationType.mention;
    case 'reblog':
    case 'renote':
      return NotificationType.reblog;
    case 'favourite':
      return NotificationType.favourite;
    case 'follow':
      return NotificationType.follow;
    case 'follow_request':
      return NotificationType.followRequest;
    case 'reaction':
      return NotificationType.reaction;
    case 'poll':
      return NotificationType.poll;
    case 'update':
      return NotificationType.update;
    case 'login':
      return NotificationType.login;
    case 'create_token':
      return NotificationType.createToken;
    default:
      return NotificationType.other;
  }
}
