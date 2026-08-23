#ifndef RUNNER_LOCAL_STATE_FILES_H_
#define RUNNER_LOCAL_STATE_FILES_H_

#include <string>

// FullTrust 本体 (runner / wns_push.cpp) と AppContainer のバックグラウンド
// タスク DLL (push_background_task.cpp) がプロセスを跨いで共有する LocalState
// ファイル名 (#474 フェーズ C)。writer と reader が別リテラルで持つと、片方
// だけ改名したときにサイレントに鍵/観測の受け渡しが壊れるため 1 箇所へ集約
// する (#764)。
//
// ⚠ **名前だけでなく、パスの組み立てと読み出しもここに置く (#976)。**
// #957 で `RecordBgDiagnostic` の実体を共有化したのに、パス組み立てと
// `ReadFileUtf8` は `push_background_task.cpp` / `push_diagnostics_store.cpp` /
// `wns_push.cpp` の 3 箇所に写しが残っていた。**「片方だけ改名したら壊れる」を
// 避けるためのヘッダなのに、その周りの手続きが割れている**のでは意味が薄い。
namespace capsicum {

// FullTrust 本体が書き出し、bg task が読む平文 push 鍵セット (Option A)。
constexpr wchar_t kLocalStateKeysetFile[] = L"push_keys.json";

// bg task が書き、FullTrust 起動時に runner が読んで消す観測単一スロット。
constexpr wchar_t kLocalStateDiagFile[] = L"push_diag.json";

// FullTrust 本体（Dart 由来）が書き、in-process 受信 / bg task が読む、アカウント
// 別の reblog/post 表示ラベル (#770)。native はプロセスを跨いで Dart の
// shared_preferences（NotificationLabelCache）を読めないため、push_keys.json と
// 同じ「Dart が用意 → LocalState 経由で native が読む」契約で共有する。形式は
// { "user@host": "{\"reblog\":\"リキュア！\",\"post\":\"投稿\"}" }（値は鍵セットと
// 同じく JSON 文字列の入れ子）。不在時は既定ラベル（ブースト/投稿）へフォールバック。
constexpr wchar_t kLocalStatePushLabelsFile[] = L"push_labels.json";

// LocalState 直下のファイルの絶対パス。
//
// ⚠ **投げない。**非パッケージ起動（`flutter run -d windows`）では LocalFolder
// を引けないので、そのときは空文字列を返す。呼び出し側は「この経路は使えない」
// と読んで素通りすればよく、try で囲う必要は無い。
std::wstring LocalStateFilePath(const wchar_t* name);

// ファイルを UTF-8 のまま読む。不在・空・読めない・パスが空はすべて空文字列。
std::string ReadFileUtf8(const std::wstring& path);

// [LocalStateFilePath] + [ReadFileUtf8]。読むだけの呼び出し側はこちらを使う。
std::string ReadLocalStateFileUtf8(const wchar_t* name);

}  // namespace capsicum

#endif  // RUNNER_LOCAL_STATE_FILES_H_
