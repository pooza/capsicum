import '../../model/announcement.dart';

abstract mixin class AnnouncementSupport {
  Future<List<Announcement>> getAnnouncements();
  Future<void> dismissAnnouncement(String id);
}
