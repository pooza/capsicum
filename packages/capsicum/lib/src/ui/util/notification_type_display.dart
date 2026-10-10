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
    case NotificationType.chat:
      return const NotificationTypeDisplay(
        icon: Icons.chat_bubble_outline,
        label: 'メッセージ',
      );
    case NotificationType.announcement:
      return const NotificationTypeDisplay(icon: Icons.campaign, label: 'お知らせ');
    case NotificationType.achievementEarned:
      return const NotificationTypeDisplay(
        icon: Icons.emoji_events,
        label: '実績を解除',
      );
    case NotificationType.addedToCollection:
      return const NotificationTypeDisplay(
        icon: Icons.bookmark_add,
        label: 'コレクションに追加',
      );
    case NotificationType.collectionUpdate:
      return const NotificationTypeDisplay(
        icon: Icons.collections_bookmark,
        label: 'コレクションを更新',
      );
    case NotificationType.severedRelationships:
      return const NotificationTypeDisplay(
        icon: Icons.link_off,
        label: '関係が失われました',
      );
    case NotificationType.moderationWarning:
      return const NotificationTypeDisplay(
        icon: Icons.gavel,
        label: '管理者からの警告',
      );
    // #1177 で足した種別。⚠ **投稿が付かないものは、見出しが唯一の手掛かり。**
    case NotificationType.newPost:
      return NotificationTypeDisplay(
        icon: Icons.fiber_new,
        label: '新しい$postLabel',
      );
    case NotificationType.quote:
      return const NotificationTypeDisplay(
        icon: Icons.format_quote,
        label: '引用',
      );
    case NotificationType.quotedUpdate:
      return const NotificationTypeDisplay(
        icon: Icons.edit_note,
        label: '引用元を編集',
      );
    case NotificationType.annualReport:
      return const NotificationTypeDisplay(
        icon: Icons.auto_awesome,
        label: '年間まとめ',
      );
    case NotificationType.adminSignUp:
      return const NotificationTypeDisplay(
        icon: Icons.how_to_reg,
        label: '新規登録',
      );
    case NotificationType.adminReport:
      return const NotificationTypeDisplay(icon: Icons.flag, label: '通報');
    case NotificationType.scheduledPostPosted:
      return NotificationTypeDisplay(
        icon: Icons.schedule_send,
        label: '予約$postLabelを投稿',
      );
    // ⚠⚠ **この Issue でいちばん実害がある種別。**「投稿したつもりが出ていない」
    // に気づけるかどうかが、この 1 行にかかっている。
    case NotificationType.scheduledPostFailed:
      return NotificationTypeDisplay(
        icon: Icons.error_outline,
        label: '予約$postLabelが失敗',
      );
    case NotificationType.followRequestAccepted:
      return const NotificationTypeDisplay(
        icon: Icons.how_to_reg,
        label: 'フォローが承認されました',
      );
    case NotificationType.roleAssigned:
      return const NotificationTypeDisplay(
        icon: Icons.badge,
        label: 'ロールが付与されました',
      );
    case NotificationType.chatInvitation:
      return const NotificationTypeDisplay(
        icon: Icons.group_add,
        label: 'メッセージのルームに招待',
      );
    case NotificationType.exportCompleted:
      return const NotificationTypeDisplay(
        icon: Icons.download_done,
        label: '書き出しが完了',
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
    // Misskey: reply は概念的に「メンションされた」と同じ扱い
    case 'reply':
      return NotificationType.mention;
    // ⚠⚠ **`quote` を mention から外した (#1177)。**#248 以来「メンション」と
    // 出していたが、**種別フィルタで切り分けられない**（表が送信名の正本でも
    // あるため・#1042）。⚠ **プッシュの見出しが「引用」に変わる。**
    case 'quote':
      return NotificationType.quote;
    case 'reblog':
    case 'renote':
      return NotificationType.reblog;
    case 'favourite':
      return NotificationType.favourite;
    case 'follow':
      return NotificationType.follow;
    case 'follow_request':
    // Misskey: receiveFollowRequest
    case 'receiveFollowRequest':
      return NotificationType.followRequest;
    case 'reaction':
      return NotificationType.reaction;
    case 'poll':
    // Misskey: pollEnded（Mastodon の poll 相当）
    case 'pollEnded':
      return NotificationType.poll;
    case 'update':
      return NotificationType.update;
    case 'login':
      return NotificationType.login;
    case 'create_token':
    // ⚠ Misskey の REST は `createToken`（camelCase）。**push 側に綴りが無く、
    // アプリ内では読めるのにプッシュだけ「通知」になっていた**（#1177 の
    // 検査で発見）。
    case 'createToken':
      return NotificationType.createToken;
    // Misskey 新 chat の Web Push 専用 type (#248)。/api/i/notifications には
    // 来ないが push payload 経由で届く。
    case 'newChatMessage':
      return NotificationType.chat;
    // capsicum-relay 経由で配信される「お知らせ」push (#477)。Mastodon /
    // Misskey 標準の通知 type には存在せず、capsicum-relay が独自に発火する。
    case 'announcement':
      return NotificationType.announcement;
    // Misskey の実績解除通知 (#918)。/api/i/notifications と push payload の
    // 双方で `achievementEarned`。
    case 'achievementEarned':
      return NotificationType.achievementEarned;
    // #1177 で足した種別。⚠ **ネイティブの NotificationTypeLabel.swift と
    // 同じ綴りを持たせること**（プッシュの見出しはあちらが作る）。
    case 'status':
    case 'note':
      return NotificationType.newPost;
    case 'quoted_update':
      return NotificationType.quotedUpdate;
    case 'annual_report':
      return NotificationType.annualReport;
    case 'admin.sign_up':
      return NotificationType.adminSignUp;
    case 'admin.report':
      return NotificationType.adminReport;
    case 'scheduledNotePosted':
      return NotificationType.scheduledPostPosted;
    case 'scheduledNotePostFailed':
      return NotificationType.scheduledPostFailed;
    case 'followRequestAccepted':
      return NotificationType.followRequestAccepted;
    case 'roleAssigned':
      return NotificationType.roleAssigned;
    case 'chatRoomInvitationReceived':
      return NotificationType.chatInvitation;
    case 'exportCompleted':
      return NotificationType.exportCompleted;
    // Mastodon 4.6 Collections の被フィーチャー通知 (#741)。
    case 'added_to_collection':
      return NotificationType.addedToCollection;
    case 'collection_update':
      return NotificationType.collectionUpdate;
    // 関係の切断・モデレーション警告 (#1084)。
    case 'severed_relationships':
      return NotificationType.severedRelationships;
    case 'moderation_warning':
      return NotificationType.moderationWarning;
    default:
      return NotificationType.other;
  }
}
