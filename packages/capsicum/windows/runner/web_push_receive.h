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

// capsicum-relay がお知らせ (announcement) 用に組み立てる**無暗号化**エンベロープ
// から表示フィールドを取り出す (#477 / #978)。`{notification_type:"announcement",
// server, announcement_id, announcement_content, announcement_body,
// announcement_published_at, account}` を受け、鍵も復号も要さない。
//
// [HandleWnsRawPayload] とは別関数にしてある。起動中の in-process 受信
// (wns_push.cpp) はお知らせを WebSocket 経路 (#569) が既に出しているので**表示
// してはならず**、両方を 1 つの関数にすると起動中に二重に出る。呼ぶのは
// バックグラウンドタスク（アプリ終了中）だけ。
//
// 本文は relay が整形済みの `announcement_body` をそのまま使う。`announcement_
// content` は HTML のままで、剥がして 80 文字に切る規則は Ruby
// (AnnouncementWorker#summarize_content) と Dart
// (PushMessageDispatcher.synthesizeAnnouncementBody) に既にある。ここで 3 つ目を
// 書くと UTF-8 の文字数え（バイトで切ると日本語が壊れる）まで再実装することに
// なるため、整形は relay 側に寄せた。
//
// title はサーバーから来ない。`announcement` の統一ラベル（「お知らせ」）を
// [ResolveDisplayTitle] で解決する。
//
// notification_id は WebSocket 経路 (#569 `notification_streaming.dart`) が使う
// `announcement:<id>` と**同じ表現**にする。両経路のトースト Tag が揃い、起動
// 直後に同じお知らせが streaming から出ても OS 側で畳める (#933)。
//
// 成功時 true。false のとき `error` は:
//   - "not an announcement"      : notification_type が announcement でない
//                                  （＝暗号化通知。呼び出し側が復号経路へ回す）
//   - "invalid envelope"         : エンベロープ JSON が不正
//   - "missing account"          : account が無い
//   - "missing announcement body": relay が整形本文を載せていない（旧 relay）
bool TryBuildAnnouncementDisplay(const std::string& raw_payload,
                                 PushDisplay* out,
                                 std::string* error = nullptr);

}  // namespace capsicum

#endif  // RUNNER_WEB_PUSH_RECEIVE_H_
