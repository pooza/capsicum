#ifndef RUNNER_LOCAL_STATE_FILES_H_
#define RUNNER_LOCAL_STATE_FILES_H_

// FullTrust 本体 (runner / wns_push.cpp) と AppContainer のバックグラウンド
// タスク DLL (push_background_task.cpp) がプロセスを跨いで共有する LocalState
// ファイル名 (#474 フェーズ C)。writer と reader が別リテラルで持つと、片方
// だけ改名したときにサイレントに鍵/観測の受け渡しが壊れるため 1 箇所へ集約
// する (#764)。
namespace capsicum {

// FullTrust 本体が書き出し、bg task が読む平文 push 鍵セット (Option A)。
constexpr wchar_t kLocalStateKeysetFile[] = L"push_keys.json";

// bg task が書き、FullTrust 起動時に runner が読んで消す観測単一スロット。
constexpr wchar_t kLocalStateDiagFile[] = L"push_diag.json";

}  // namespace capsicum

#endif  // RUNNER_LOCAL_STATE_FILES_H_
