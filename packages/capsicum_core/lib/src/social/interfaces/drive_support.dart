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
}
