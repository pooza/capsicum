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
  Future<DriveFolder> createDriveFolder(String name, {String? parentId});
  Future<void> deleteDriveFolder(String folderId);
  Future<void> renameDriveFolder(String folderId, String newName);
}
