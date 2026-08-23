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
  if (key.empty()) return;
  // ⚠⚠ **席の確保と昇格を 1 つの排他区間でやる** (#1015 Codex P2)。公開 API の
  // TryClaim を経由すると間で解錠されるので、その隙間に ReleaseClaim が入って
  // 予約が消え、下の在籍確認が空振りして shown_ を立てられない。**トースト
  // 自体は表示済みなのに記録が残らず**、あとから届いた同じ通知が未出と判定
  // されて二重表示になる。
  std::lock_guard<std::mutex> lock(mutex_);
  // ⚠ **本体を写して 2 つ並べない** — 上限の押し出しと FIFO 順序の扱いが
  // 片方だけ直る事故になる。
  TryClaimLocked(key);
  // ⚠ **押し出された直後なら shown_ にも入れない。** keys_ の部分集合という
  // 不変条件が崩れると、あとで押し出しても shown_ に残り続けて漏れる。
  if (keys_.find(key) == keys_.end()) return;
  shown_.insert(key);
}

bool NotificationDedupRegistry::TryClaim(const std::string& key) {
  if (key.empty()) return true;
  std::lock_guard<std::mutex> lock(mutex_);
  return TryClaimLocked(key);
}

bool NotificationDedupRegistry::TryClaimLocked(const std::string& key) {
  if (!keys_.insert(key).second) {
    // 既出＝他経路が先に取った。⚠ 順序は動かさない（LRU ではなく FIFO）。
    return false;
  }
  order_.push_back(key);
  size_t evicted = 0;
  while (order_.size() > kMaxKeys) {
    keys_.erase(order_.front());
    shown_.erase(order_.front());
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
  // ⚠ **他経路が実際に表示していたら取り消さない** (#1015 Codex P2)。claim を
  // 取ってから ShowRawToast が返るまでの間に WebSocket 経路 (#569) が同じ通知
  // を出して addEmitted を撃つことがある。そこで消すと「出した」という記録が
  // 消え、あとから届いた同じ通知が未出と判定されて二重表示が復活する。
  if (shown_.find(key) != shown_.end()) return;
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
  shown_.clear();
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
