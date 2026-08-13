#ifndef RUNNER_PUSH_DIAGNOSTICS_STORE_H_
#define RUNNER_PUSH_DIAGNOSTICS_STORE_H_

#include <string>

// push 観測レコード (#474 フェーズ C) の LocalState 単一スロットへの書き込み。
// JSON の組み立てそのものは純粋ロジックの push_diagnostics.h に置き、こちらは
// WinRT (ApplicationData.LocalFolder 解決) とファイル I/O だけを持つ。
//
// **書き手は 2 つある**（#957 で runner 側を追加）:
//   - AppContainer の bg task DLL (push_background_task.cpp) — アプリ完全終了中
//   - FullTrust の runner (wns_push.cpp) — 起動中の in-process 受信
// 読み手は常に runner の [ConsumePushDiagnosticsJson]（起動時に 1 回、読んだら
// 消す）で、そこから Dart → Sentry へ流れる。runner が書いた分は**次回起動**で
// 回収される点に注意（bg task 分と同じ遅延契約）。
namespace capsicum {

// 観測コード [code]（push_diagnostics.h のコード一覧を参照）と、任意の
// [host]（サーバードメインのみ。不明なら空文字列）を単一スロットへ 1 件マージ
// して書き込む。失敗（LocalFolder 解決不可・I/O エラー・例外）は黙殺する
// ——観測機構が通知本体を巻き込まないため。プロセス内の同時記録は直列化する。
void RecordPushDiagnostic(const std::string& code, const std::string& host);

}  // namespace capsicum

#endif  // RUNNER_PUSH_DIAGNOSTICS_STORE_H_
