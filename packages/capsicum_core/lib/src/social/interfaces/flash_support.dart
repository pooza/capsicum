import '../../model/flash.dart';

abstract mixin class FlashSupport {
  Future<List<Flash>> getFeaturedFlashes();
}
