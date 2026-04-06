import '../../model/achievement.dart';

abstract mixin class AchievementSupport {
  Future<List<Achievement>> getAchievements(String userId);
}
