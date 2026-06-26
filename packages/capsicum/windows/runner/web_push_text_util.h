#ifndef RUNNER_WEB_PUSH_TEXT_UTIL_H_
#define RUNNER_WEB_PUSH_TEXT_UTIL_H_

#include <cstdint>
#include <string>
#include <vector>

// Web Push payload を扱う際の文字列プリミティブ (#764)。
//
// 以前は AppendUtf8 / ParseHex4 / base64 デコーダ / JSON 文字列エスケープが
// web_push_payload.cpp / web_push_key_reader.cpp / web_push_receive.cpp に
// ほぼ逐語コピーされており、\uXXXX やサロゲートの不具合修正を 3 箇所に追従
// させる必要があった。ここへ集約し、runner ターゲットと push bg task DLL の
// 両方からリンクして 1 箇所修正で済むようにする。
namespace capsicum {

// コードポイントを UTF-8 にして末尾へ追加する（JSON \uXXXX のデコード用）。
void AppendUtf8(uint32_t cp, std::string* out);

// `s` の `pos` から始まる 4 桁 16 進数を読み `*out` に格納する。範囲外・非
// 16 進文字があれば false（`*out` は不定）。JSON \uXXXX の桁読みに使う。
bool ParseHex4(const std::string& s, size_t pos, uint32_t* out);

// base64 デコード（パディング '=' は読み飛ばし、padded / unpadded どちらも
// 受ける）。base64url の '-' / '_' は常に 62 / 63 として受ける。`accept_standard`
// が true なら標準 base64 の '+' / '/' も 62 / 63 として受ける（false なら
// 厳密 base64url で '+' / '/' は不正文字扱い）。不正文字があれば false。
bool Base64Decode(const std::string& in, std::vector<uint8_t>* out,
                  bool accept_standard);

// JSON 文字列値のエスケープ（JSON 文字列パースの逆。鍵セットマップを
// LocalState へ再シリアライズするのに使う、#474 フェーズ C）。
std::string EscapeJsonString(const std::string& s);

}  // namespace capsicum

#endif  // RUNNER_WEB_PUSH_TEXT_UTIL_H_
