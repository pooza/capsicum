#include "notification_dedup.h"

namespace capsicum {

NotificationDedupRegistry& NotificationDedupRegistry::Instance() {
  // 関数ローカル static。C++11 以降はスレッドセーフに 1 度だけ初期化される。
  static NotificationDedupRegistry instance;
  return instance;
}

void NotificationDedupRegistry::MarkShown(const std::string& key) {
  if (key.empty()) return;
  std::lock_guard<std::mutex> lock(mutex_);
  if (keys_.size() >= kMaxKeys) {
    keys_.clear();
  }
  keys_.insert(key);
}

bool NotificationDedupRegistry::WasShown(const std::string& key) {
  if (key.empty()) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  return keys_.find(key) != keys_.end();
}

void NotificationDedupRegistry::Reset() {
  std::lock_guard<std::mutex> lock(mutex_);
  keys_.clear();
}

size_t NotificationDedupRegistry::SizeForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  return keys_.size();
}

}  // namespace capsicum
