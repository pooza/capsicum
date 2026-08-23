#include "push_diagnostics_store.h"

#include <windows.h>

#include <cstdint>
#include <fstream>
#include <mutex>
#include <string>

#include "local_state_files.h"
#include "push_diagnostics.h"

namespace capsicum {

namespace {

// 同一プロセス内の同時記録を直列化する（read-modify-write が交錯して count を
// 取りこぼさないように）。in-process 受信の PushNotificationReceived は MTA の
// RPC スレッドで発火するため、起動中は並走しうる。
//
// ⚠ プロセスを跨いだ排他ではない。bg task と runner が同時に書く状況は
// args.Cancel(true) の抑止で実質起きないが、起きたとしても失うのは観測 1 件で
// あって通知本体ではない（ファイル単位の truncate-write なので壊れた JSON が
// 残っても、次の記録が count=1 で復帰する）。
std::mutex& RecordMutex() {
  static std::mutex m;
  return m;
}

// UNIX エポックからのミリ秒。FILETIME（1601 起点・100ns 単位）から換算する。
int64_t NowUnixMs() {
  FILETIME ft;
  GetSystemTimeAsFileTime(&ft);
  ULARGE_INTEGER u;
  u.LowPart = ft.dwLowDateTime;
  u.HighPart = ft.dwHighDateTime;
  // 1601-01-01 → 1970-01-01 は 11644473600 秒。
  return static_cast<int64_t>(u.QuadPart / 10000ULL) - 11644473600000LL;
}

}  // namespace

void RecordPushDiagnostic(const std::string& code, const std::string& host) {
  std::lock_guard<std::mutex> guard(RecordMutex());
  try {
    // パス組み立てと読み出しは local_state_files.h の共有実装 (#976)。
    const std::wstring path = LocalStateFilePath(kLocalStateDiagFile);
    if (path.empty()) return;  // 非 MSIX 起動。観測は諦める。
    const std::string prev = ReadFileUtf8(path);
    const std::string next =
        BuildPushDiagnosticJson(prev, code, host, NowUnixMs());
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (f) {
      f.write(next.data(), static_cast<std::streamsize>(next.size()));
    }
  } catch (...) {
    // LocalFolder 解決不可（非 MSIX 起動）・I/O 失敗。観測は諦める。
  }
}

}  // namespace capsicum
