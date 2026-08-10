#include "notification_tag.h"

namespace capsicum {

uint32_t StableNotificationTag(const std::string& key) {
  constexpr uint32_t kOffsetBasis = 0x811c9dc5u;
  constexpr uint32_t kPrime = 0x01000193u;
  uint32_t hash = kOffsetBasis;
  for (unsigned char byte : key) {
    hash ^= static_cast<uint32_t>(byte);
    hash *= kPrime;  // uint32_t は 2^32 で自然に折り返す。
  }
  return hash & 0x7fffffffu;
}

std::string NotificationTagKey(const std::string& account,
                               const std::string& notification_id) {
  return account + "|" + notification_id;
}

std::string NotificationTagFor(const std::string& account,
                               const std::string& notification_id) {
  // ID が無いなら Tag を付けない。理由はヘッダ参照 (#956)。
  if (notification_id.empty()) {
    return std::string();
  }
  return std::to_string(
      StableNotificationTag(NotificationTagKey(account, notification_id)));
}

}  // namespace capsicum
