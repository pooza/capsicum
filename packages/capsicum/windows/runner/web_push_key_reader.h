#ifndef RUNNER_WEB_PUSH_KEY_READER_H_
#define RUNNER_WEB_PUSH_KEY_READER_H_

#include <cstdint>
#include <string>
#include <vector>

// flutter_secure_storage に保存された Web Push 鍵セットを Dart 非依存で読む
// (#474 フェーズ2)。WNS バックグラウンドタスク（アプリ完全終了中・別プロセス）
// から復号鍵を取り出すための部品で、macOS NSE の `PushKeyReader.swift` の
// Windows 版にあたる。
//
// 【保存形式】flutter_secure_storage_windows 3.x は値を **Dart (win32 FFI)**
// 実装で書く（パッケージ同梱の C++ プラグインは 3.0.0 で「Migrated to win32
// package replacing C」された死んだ旧実装なので参照しないこと）。実体は
// `getApplicationSupportDirectory()` 配下の単一ファイル
// `flutter_secure_storage.dat` で、全 key→value マップを
//   CryptProtectData( utf8( jsonEncode(Map<String,String>) ) )
// で DPAPI 暗号化（オプショナルエントロピー無し・ユーザースコープ）したもの。
// キーは prefix 無しの生キーがそのままマップキーになる。
//
// 鍵セットは Dart 側 [PushKeyStore] が
//   capsicum_push_keyset_{storageKey}  (storageKey = "{prefix}://{username}@{host}")
// というキーに、値として `{"p256dh":..,"auth":..,"priv":..}`（各 base64url）の
// JSON 文字列を入れている。
//
// runner ターゲットは `_HAS_EXCEPTIONS=0`（例外無効）なので、失敗は例外でなく
// 戻り値 (bool) + 任意の error 文字列で表す。Flutter / WinRT には依存しない。
namespace capsicum {

// Web Push 復号に必要な鍵素材（base64url をデコード済みの生バイト）。
struct PushKeys {
  std::vector<uint8_t> p256dh;     // 非圧縮 P-256 公開鍵 (65 バイト, 先頭 0x04)
  std::vector<uint8_t> auth;       // auth secret (16 バイト)
  std::vector<uint8_t> private_d;  // P-256 秘密鍵 D 値 (32 バイト)
};

// `dat_file_path` の flutter_secure_storage.dat を DPAPI 復号し、`account`
// (`username@host`) に対応する push 鍵セットを取り出す。
//
// adapter 種別は呼び出し側からは判らないため、storage key prefix を
// mastodon → misskey の順に試す（Dart [PushKeyStore] / macOS [PushKeyReader] と
// 同じ戦略）。
//
// 成功時は true を返し `*out` にデコード済み鍵を格納する。鍵不在・ファイル不在・
// DPAPI 復号失敗・JSON 不正・鍵長不正のときは false を返し、`error` が非 null
// なら理由を `*error` に設定する。
bool ReadPushKeys(const std::wstring& dat_file_path,
                  const std::string& account,
                  PushKeys* out,
                  std::string* error = nullptr);

// flutter_secure_storage.dat を DPAPI 復号し、push 鍵セット
// (capsicum_push_keyset_* で始まるエントリ) **だけ** を平文 JSON マップ文字列
// として返す（#474 フェーズ C / Option A）。アカウントトークン等の他の秘密は
// 含めない。FullTrust 本体（runner）がこれを AppContainer のバックグラウンド
// タスクからも読める LocalState に書き出すために使う。バックグラウンドタスクは
// AppContainer サンドボックスのためローミング %APPDATA% の .dat を読めず DPAPI
// 復号もできないので、平文化した鍵セットを LocalState 経由で渡す（LocalState は
// パッケージ専有 ACL のため第三者からは読めない。macOS の App Group 共有に相当）。
//
// 成功時 true で `*out_json` を埋める。.dat 不在・DPAPI 失敗・パース失敗で false。
bool ExtractPushKeysetMapJson(const std::wstring& dat_file_path,
                              std::string* out_json,
                              std::string* error = nullptr);

// 平文の鍵セット JSON マップ（[ExtractPushKeysetMapJson] の出力、または
// flutter_secure_storage.dat を復号した平文と同形式）から `account`
// (`username@host`) の push 鍵を取り出す。[ReadPushKeys] の「DPAPI 復号後」の
// 処理と同一で、バックグラウンドタスクが LocalState の鍵を読むのに使う。
bool ReadPushKeysFromKeysetJson(const std::string& keyset_map_json,
                                const std::string& account,
                                PushKeys* out,
                                std::string* error = nullptr);

// LocalState の push_labels.json（[kLocalStatePushLabelsFile]）内容から `account`
// (`username@host`) の reblog / post 表示ラベルを引く (#770)。形式は
//   { "user@host": "{\"reblog\":\"リキュア！\",\"post\":\"投稿\"}" }
// （値は鍵セットと同じく JSON 文字列の入れ子）。**見つかった項目だけ** `*reblog` /
// `*post` を上書きするので、呼び出し側は既定ラベル（ブースト/投稿）を入れてから
// 呼ぶこと。JSON 空・パース不能・account 不在・項目欠落・空文字列のときは何もしない
// （既定ラベルのまま）。鍵と違い失敗しても通知表示自体は続くので戻り値は持たない。
void ReadPushLabelsFromJson(const std::string& labels_json,
                            const std::string& account,
                            std::string* reblog,
                            std::string* post);

// 既定の保存先 `%APPDATA%\{CompanyName}\{ProductName}\flutter_secure_storage.dat`
// を返す（path_provider の Windows 実装と同じ解決規則。CompanyName /
// ProductName は **実行中 exe** のバージョン情報から取る）。解決に失敗したときは
// 空文字列を返す。in-process（runner exe 上）の受信で使う。
std::wstring DefaultSecureStorageDatPath();

// 指定した exe のバージョン情報（CompanyName / ProductName）から
// `%APPDATA%\{CompanyName}\{ProductName}\flutter_secure_storage.dat` を解決する。
//
// バックグラウンドタスク (#474 フェーズ C) は backgroundTaskHost.exe 上で動くため
// `DefaultSecureStorageDatPath()`（実行中 exe 基準）では別ディレクトリを指す。
// タスク DLL は同梱の capsicum.exe パスを渡してメインアプリと同じ .dat を解決する
// （path_provider の CompanyName / ProductName は runner exe の VERSIONINFO 由来）。
// 解決失敗時は空文字列。
std::wstring SecureStorageDatPathForExe(const std::wstring& exe_path);

}  // namespace capsicum

#endif  // RUNNER_WEB_PUSH_KEY_READER_H_
