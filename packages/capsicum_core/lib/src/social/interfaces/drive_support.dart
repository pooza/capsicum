import '../../model/attachment.dart';
import '../../model/drive_folder.dart';
import '../../model/timeline_query.dart';

abstract mixin class DriveSupport {
  Future<List<Attachment>> getDriveFiles({
    String? folderId,
    TimelineQuery? query,
  });
  Future<List<DriveFolder>> getDriveFolders({
    String? folderId,
    TimelineQuery? query,
  });
  Future<void> deleteDriveFile(String fileId);
  Future<void> renameDriveFile(String fileId, String newName);
  Future<void> moveDriveFile(String fileId, String? folderId);

  /// ドライブファイルの ALT（説明）を書き換える (#1027-F1)。
  ///
  /// ⚠ **`MediaUpdateSupport.updateAttachmentDescription` とは別物。**あちらは
  /// **投稿済みの添付**を直す口で `postId` を要る（Mastodon は投稿の更新 API
  /// 経由でしか直せないため）。こちらは**まだ投稿していない**ドライブファイル
  /// が対象なので postId が存在しない。
  ///
  /// ⚠⚠ **ドライブのファイルは実体が 1 つ。**書き換えると、**そのファイルを
  /// 使っている過去の投稿の ALT も変わる**。Misskey の Web UI と同じ挙動で、
  /// 仕様として受け入れている（#1027 で判断）。
  ///
  /// 空文字は「消す」。「変更なし」ではない。
  Future<void> updateDriveFileDescription(String fileId, String description);
  Future<DriveFolder> createDriveFolder(String name, {String? parentId});
  Future<void> deleteDriveFolder(String folderId);
  Future<void> renameDriveFolder(String folderId, String newName);

  /// フォルダを別の親フォルダに移動する。`null` で root へ移動 (#437)。
  Future<void> moveDriveFolder(String folderId, String? parentId);
}
