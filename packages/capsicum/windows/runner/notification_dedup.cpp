#include "notification_dedup.h"

#include <windows.h>

#include <algorithm>
#include <cstdio>

namespace capsicum {

NotificationDedupRegistry& NotificationDedupRegistry::Instance() {
  // 関数ローカル static。C++11 以降はスレッドセーフに 1 度だけ初期化される。
  static NotificationDedupRegistry instance;
  return instance;
}

void NotificationDedupRegistry::MarkShown(const std::string& key) {
  // 「記録する」は「表示権を取って結果を捨てる」と同じ。⚠ **本体を写して 2 つ
  // 並べない** — 上限の押し出しと FIFO 順序の扱いが片方だけ直る事故になる。
  TryClaim(key);
}

bool NotificationDedupRegistry::TryClaim(const std::string& key) {
  if (key.empty()) return true;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!keys_.insert(key).second) {
    // 既出＝他経路が先に取った。⚠ 順序は動かさない（LRU ではなく FIFO）。
    return false;
  }
  order_.push_back(key);
  size_t evicted = 0;
  while (order_.size() > kMaxKeys) {
    keys_.erase(order_.front());
    order_.pop_front();
    ++dropped_;
    ++evicted;
  }
  if (evicted > 0) LogFirstEvictionLocked(evicted);
  return true;
}

void NotificationDedupRegistry::ReleaseClaim(const std::string& key) {
  if (key.empty()) return;
  std::lock_guard<std::mutex> lock(mutex_);
  if (keys_.erase(key) == 0) return;
  const auto it = std::find(order_.begin(), order_.end(), key);
  if (it != order_.end()) order_.erase(it);
}

bool NotificationDedupRegistry::WasShown(const std::string& key) {
  if (key.empty()) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  return keys_.find(key) != keys_.end();
}

void NotificationDedupRegistry::Reset() {
  std::lock_guard<std::mutex> lock(mutex_);
  keys_.clear();
  order_.clear();
  dropped_ = 0;
  eviction_logged_ = false;
}

size_t NotificationDedupRegistry::SizeForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  return keys_.size();
}

size_t NotificationDedupRegistry::DroppedForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  return dropped_;
}

void NotificationDedupRegistry::LogFirstEvictionLocked(size_t evicted) {
  if (eviction_logged_) return;
  eviction_logged_ = true;
  char buf[192];
  // 書式は macOS (NSLog) / Dart (debugPrint) の同種ログに合わせる。
  std::snprintf(buf, sizeof(buf),
                "capsicum: push.desktop: dedup \"shown\" evicted %zu oldest "
                "(size=%zu/%zu, total_dropped=%zu)\n",
                evicted, order_.size(), kMaxKeys, dropped_);
  OutputDebugStringA(buf);
}

}  // namespace capsicum
