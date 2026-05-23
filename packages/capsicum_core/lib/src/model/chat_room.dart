import 'user.dart';

/// Misskey の chat ルーム (グループチャット)。`/api/chat/rooms/*` の `ChatRoom`
/// レスポンスに対応。`owner` は作成者でメンバー管理権限を持つ。
class ChatRoom {
  final String id;
  final DateTime createdAt;
  final String name;
  final String description;
  final String ownerId;
  final User owner;

  /// 自分がこのルームをミュートしているか。`/show` / `/joining` のレスポンス
  /// で me を渡したときのみ意味を持つ。
  final bool isMuted;

  /// 自分宛の招待が pending で残っているか。invitations/inbox を別途叩かずに
  /// 1 レスポンスで UI 判定できるようサーバー側が含めている。
  final bool invitationExists;

  const ChatRoom({
    required this.id,
    required this.createdAt,
    required this.name,
    required this.description,
    required this.ownerId,
    required this.owner,
    this.isMuted = false,
    this.invitationExists = false,
  });
}
