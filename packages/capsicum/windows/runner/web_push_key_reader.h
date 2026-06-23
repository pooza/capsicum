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

// 既定の保存先 `%APPDATA%\{CompanyName}\{ProductName}\flutter_secure_storage.dat`
// を返す（path_provider の Windows 実装と同じ解決規則。CompanyName /
// ProductName は実行中 exe のバージョン情報から取る）。解決に失敗したときは
// 空文字列を返す。
//
// 注意: バックグラウンドタスクを別 exe にする場合、その exe のバージョン情報の
// CompanyName / ProductName をメインアプリ（net.shrieker / capsicum）と一致させ
// ないと別ディレクトリを指す。bg task 配線時に揃えること。
std::wstring DefaultSecureStorageDatPath();

}  // namespace capsicum

#endif  // RUNNER_WEB_PUSH_KEY_READER_H_
