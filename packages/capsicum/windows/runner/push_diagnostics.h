#ifndef RUNNER_PUSH_DIAGNOSTICS_H_
#define RUNNER_PUSH_DIAGNOSTICS_H_

#include <cstdint>
#include <string>

// WNS バックグラウンドタスク (#474 フェーズ C) の観測レコード。AppContainer の
// bg task は別プロセス・純 C++ で Sentry SDK を持てず、コンソールも無いため、
// 受信/復号/表示の成否を LocalState の 1 スロット JSON に記録しておき、次回
// FullTrust 起動時に runner が読み出して Dart 経由で Sentry に吸い上げる。
// macOS NSE の FailureRecorder（App Group UserDefaults → Dart PushFailureRecorder）
// と同型。
//
// 本ヘッダは JSON の組み立て / 解析という純粋ロジックだけを公開する（WinRT /
// ファイル I/O は呼び出し側 = bg task の record、runner の consume が持つ）。
// runner は `_HAS_EXCEPTIONS=0` のため失敗は戻り値 (bool) で表す。
namespace capsicum {

// 観測コード。Dart 側 (push_diagnostics consume → Sentry) の level 判定と
// 揃えること。
//   bgtask.shown        : 復号成功 → トースト表示成功（正常・info）
//   bgtask.show_failed  : 復号成功 → トースト表示失敗（warning, #957）
//   bgtask.not_encrypted: 暗号化通知でも announcement でもない（正常・info）
//   お知らせ push (#978。無暗号化・鍵を要さない):
//   bgtask.announcement_shown       : トースト表示成功（正常・info）
//   bgtask.announcement_show_failed : 表示失敗（warning）
//   bgtask.announcement_no_body     : relay が整形済み本文を載せていない
//                                     （relay#36 Phase 2 前・warning）
//   bgtask.announcement_bad_payload : エンベロープ不正 / account 欠落（warning）
//   ⚠ **通常の通知と同じ bgtask.shown に合流させない**。「bgtask.shown が
//   無ければ bg task 未起動」というトリアージ規則は通知 push の母数の上で
//   成り立っており、発火契機の違うお知らせを混ぜると母数が濁る。
//   bgtask.not_raw      : raw push trigger に RawNotification 以外が来た（info。
//                         起動した事実のみ残す）
//   bgtask.no_keyset    : LocalState に鍵セット未同期（Option A 未実行・warning）
//   bgtask.no_keys      : 当該アカウントの鍵が無い（warning）
//   bgtask.decrypt_failed / bgtask.parse_failed / bgtask.bad_payload : 異常
//   bgtask.exception    : Run() で未捕捉例外（warning）
//   wns.show_failed     : **起動中の** in-process 受信が復号に成功したのに
//                         トースト表示に失敗した（warning, #957）。bg task では
//                         なく runner が同じスロットへ書く（下記）
//
// `bgtask.` で始まらないコードは **FullTrust の runner（起動中の in-process
// 受信）が同じスロットへ書いたもの**。書き手は違うが、記録・回収・Sentry 送出の
// 機構は 1 本に保つ（二重管理を避ける）。Sentry のメッセージ接頭辞は
// `push.wns_bgtask:` のままで、fingerprint は code 別に割れる。
struct PushDiagnostic {
  std::string code;
  int64_t at_ms = 0;
  int count = 0;
  std::string host;  // サーバードメインのみ（username は載せない）。無ければ空。
};

// 既存スロット JSON [prev_json]（空可）に新しいイベントを 1 件マージした JSON を
// 返す。count は既存 +1（既存が壊れている / 空なら 1）。
//
// 代表イベント（記録する code / at_ms / host）の決め方:
//   - 単一スロットだが、未消費の異常系コードは後続の正常系イベント
//     （bgtask.shown / bgtask.not_encrypted）で上書きしない。正常系で上書きすると
//     次回起動の flush で warning が info に飲まれて消えてしまうため。
//   - したがって「新イベントが正常系 かつ 既存が異常系」のときだけ既存を温存し、
//     それ以外（異常系の到来・正常系同士・初回）は最新イベントを代表にする。
std::string BuildPushDiagnosticJson(const std::string& prev_json,
                                    const std::string& code,
                                    const std::string& host, int64_t at_ms);

// スロット JSON を解析する。レコードが無い（空 / 不正 / code 不在）なら false。
bool ParsePushDiagnosticJson(const std::string& json, PushDiagnostic* out);

// `username@host` から host 部分だけを返す。観測レコードに username を載せない
// ための正規化 (#800)。`@` を含まない / `@` が末尾なら空文字列（host 不明）。
// 記録側 (bg task / runner) が別々に持つと片方だけ直したときにズレるため、
// 純粋ロジックとしてここに置く。
std::string PushDiagnosticHostFromAccount(const std::string& account);

}  // namespace capsicum

#endif  // RUNNER_PUSH_DIAGNOSTICS_H_
