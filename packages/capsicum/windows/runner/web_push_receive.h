#ifndef RUNNER_WEB_PUSH_RECEIVE_H_
#define RUNNER_WEB_PUSH_RECEIVE_H_

#include <string>

// WNS raw 通知の生ペイロードを「エンベロープ解析 → 鍵読み → 復号 → 文面化」と
// 一気通貫で処理するオーケストレーション層 (#474 フェーズ2)。macOS NSE の
// `NotificationService.didReceive` 本体に相当し、復号器 (web_push_decrypt)・
// 鍵リーダー (web_push_key_reader)・payload パーサ (web_push_payload) を束ねる。
//
// in-process 受信（起動中の `PushNotificationReceived`）でも、out-of-process
// バックグラウンドタスク（完全終了中の `PushNotificationTrigger`）でも、受信した
// raw 文字列をこの関数に渡せば表示フィールドが得られる。WinRT / Flutter 非依存
// （純粋な文字列 I/F）なので、別プロセスのタスクホストからも再利用できる。
//
// runner は `_HAS_EXCEPTIONS=0` のため失敗は戻り値 (bool) + 任意の error 文字列。
namespace capsicum {

// 表示に必要なフィールド（空文字列 = 無し）。
struct PushDisplay {
  std::string account;          // エンベロープの宛先アカウント (username@host)
  std::string title;            // 表示用に解決済みの title（type→ラベル統一済み）
  std::string body;             // 表示本文
  std::string type;             // 通知種別（type→ラベル変換は表示側の責務）
  std::string notification_id;  // SNS 側通知 ID（dedup 用）
  std::string user_id;          // chat の遷移先 fromUser.id（chat 以外は空）
};

// relay が WNS raw として送る JSON エンベロープ `{body, encoding, server,
// account}` を処理する。`body` は base64url（標準 base64 も許容）でエンコード
// された RFC 8188 暗号文。`dat_file_path` は flutter_secure_storage.dat のパス。
//
// 成功時 true で `*out` を埋める。以下は false（`error` に段階を示す文字列）:
//   - エンベロープ JSON が不正
//   - account が無い
//   - 暗号化通知でない（body / encoding!=aes128gcm。announcement 等は呼び出し側で
//     別途処理する）
//   - body の base64url が不正 / 鍵不在 / 復号失敗 / payload パース失敗
// [push_labels_json] は LocalState の push_labels.json 内容（#770）。account 別の
// reblog / post 表示ラベルを引くのに使い、空 / 該当なしのときは既定ラベル
// （ブースト / 投稿）へフォールバックする。title 文言のみに影響し、鍵・復号には
// 関与しない。
bool HandleWnsRawPayload(const std::string& raw_payload,
                         const std::wstring& dat_file_path, PushDisplay* out,
                         std::string* error = nullptr,
                         const std::string& push_labels_json = std::string());

// [HandleWnsRawPayload] と同じだが、鍵を flutter_secure_storage.dat ではなく
// 平文の鍵セット JSON マップ（ExtractPushKeysetMapJson 出力）から引く版
// (#474 フェーズ C / Option A)。AppContainer のバックグラウンドタスクは
// ローミング %APPDATA% の .dat を読めないため、LocalState に置いた鍵セット JSON
// を読んでこちらに渡す。
bool HandleWnsRawPayloadFromKeysetJson(
    const std::string& raw_payload, const std::string& keyset_map_json,
    PushDisplay* out, std::string* error = nullptr,
    const std::string& push_labels_json = std::string());

}  // namespace capsicum

#endif  // RUNNER_WEB_PUSH_RECEIVE_H_
