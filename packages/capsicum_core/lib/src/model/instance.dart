import 'attachment.dart';
import 'user.dart';

class Instance {
  final String name;
  final String? softwareName;
  final String? description;
  final String? iconUrl;
  final String? version;
  final String? themeColor;
  final int? userCount;
  final int? postCount;
  final String? contactEmail;
  final User? contactAccount;
  final String? contactUrl;
  final List<String> rules;
  final String? privacyPolicyUrl;
  final String? statusUrl;

  /// 添付ファイルの種別ごとの最大サイズ（bytes）。サーバーが上限を返さない
  /// 場合は null（事前チェックをスキップして従来どおりサーバーエラー経路に
  /// 任せる）。Misskey は MIME によらず単一値のため、image/video/audio に
  /// 同じ値が入る。
  final int? imageSizeLimit;
  final int? videoSizeLimit;
  final int? audioSizeLimit;

  const Instance({
    required this.name,
    this.softwareName,
    this.description,
    this.iconUrl,
    this.version,
    this.themeColor,
    this.userCount,
    this.postCount,
    this.contactEmail,
    this.contactAccount,
    this.contactUrl,
    this.rules = const [],
    this.privacyPolicyUrl,
    this.statusUrl,
    this.imageSizeLimit,
    this.videoSizeLimit,
    this.audioSizeLimit,
  });

  /// 添付ファイル種別に対応する最大サイズ（bytes）。サーバーが上限を返さない
  /// 場合や、種別が判定できない場合は null。
  int? maxAttachmentSizeBytes(AttachmentType type) {
    switch (type) {
      case AttachmentType.image:
      case AttachmentType.gifv:
        return imageSizeLimit;
      case AttachmentType.video:
        return videoSizeLimit;
      case AttachmentType.audio:
        return audioSizeLimit;
      case AttachmentType.unknown:
        return null;
    }
  }
}
