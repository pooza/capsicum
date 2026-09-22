import 'package:capsicum_core/capsicum_core.dart';

/// 関係の切断・モデレーション警告の通知の本文 (#1084)。
///
/// 文言は Mastodon WebUI（`notification.relationships_severance_event.*` /
/// `notification.moderation_warning.action_*`）に合わせてある。通知一覧の
/// タイルとデスクトップ通知の両方がここを使う。
///
/// [localHost] は受信者のサーバー（WebUI の `{from}`）。[postLabel] はサーバーが
/// 設定するカスタム投稿ラベル。対象外の種別では null。
String? moderationNotificationText(
  Notification n, {
  required String localHost,
  String postLabel = '投稿',
}) {
  switch (n.type) {
    case NotificationType.severedRelationships:
      final s = n.severance;
      if (s == null) return null;
      final target = s.targetName;
      final lost = '${s.followersCount}フォロワーと${s.followingCount}フォロー';
      return switch (s.kind) {
        RelationshipSeveranceKind.domainBlock =>
          '$localHost の管理者が $target をブロックしました。これにより$lostが失われました。',
        RelationshipSeveranceKind.userDomainBlock =>
          '$target のブロックにより$lostが解除されました。',
        RelationshipSeveranceKind.accountSuspension =>
          '$localHost の管理者が $target さんを停止したため、今後このユーザーとの交流や'
              '新しい$postLabelの受け取りができなくなりました。',
        RelationshipSeveranceKind.unknown => '$target との関係が失われました。',
      };
    case NotificationType.moderationWarning:
      final w = n.moderationWarning;
      if (w == null) return null;
      return switch (w.action) {
        ModerationWarningAction.none => 'あなたのアカウントは管理者からの警告を受けています。',
        ModerationWarningAction.disable => 'あなたのアカウントは無効になりました。',
        ModerationWarningAction.markStatusesAsSensitive =>
          'あなたの$postLabelのいくつかは閲覧注意として判定されています。',
        ModerationWarningAction.deleteStatuses =>
          'あなたによるいくつかの$postLabelが削除されました。',
        ModerationWarningAction.sensitive =>
          'あなたの$postLabelはこれから閲覧注意としてマークされます。',
        ModerationWarningAction.silence => 'あなたのアカウントは制限されています。',
        ModerationWarningAction.suspend => 'あなたのアカウントは停止されました。',
        ModerationWarningAction.unknown => '管理者から警告が来ています。',
      };
    default:
      return null;
  }
}

/// 通知の詳細を Web で開く先 (#1084)。対象外の種別では null。
///
/// ⚠ **capsicum に対応する画面は無い**（切断された関係の CSV・警告への異議申し立ては
/// Web 専用）ので、WebUI の「詳細を確認」と同じページをブラウザで開く。
Uri? moderationNotificationWebUri(Notification n, {required String localHost}) {
  switch (n.type) {
    case NotificationType.severedRelationships:
      if (n.severance == null) return null;
      return Uri.https(localHost, '/severed_relationships');
    case NotificationType.moderationWarning:
      final w = n.moderationWarning;
      if (w == null) return null;
      return Uri.https(localHost, '/disputes/strikes/${w.id}');
    default:
      return null;
  }
}
