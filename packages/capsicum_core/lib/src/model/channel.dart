class Channel {
  final String id;
  final String name;
  final String? description;

  /// 作成者の id。編集できるかの判定に使う。
  final String? userId;
  final int? usersCount;
  final int? notesCount;
  final bool isFollowing;
  final bool isFavorited;
  final bool isMuting;
  final bool isSensitive;
  final bool allowRenoteToExternal;

  const Channel({
    required this.id,
    required this.name,
    this.description,
    this.userId,
    this.usersCount,
    this.notesCount,
    this.isFollowing = false,
    this.isFavorited = false,
    this.isMuting = false,
    this.isSensitive = false,
    this.allowRenoteToExternal = true,
  });
}

/// チャンネルの作成 / 編集で送る内容 (#1051)。
class ChannelDraft {
  final String name;

  /// 空なら説明を消す。
  final String description;
  final bool isSensitive;
  final bool allowRenoteToExternal;

  const ChannelDraft({
    required this.name,
    this.description = '',
    this.isSensitive = false,
    this.allowRenoteToExternal = true,
  });
}
