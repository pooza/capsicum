// notification_tag.cpp のスタンドアロン単体テスト (#933)。
//
// WebSocket 経路 (#569) と WNS 経路 (#474) のトースト Tag を揃えるための
// ハッシュを検証する。**ここのベクタは Dart 側の
// test/notification_tag_test.dart と同一の値を使っている。**片方だけ変えると
// Tag が食い違い、Windows で二重通知が復活する。値を変えるときは必ず両方を
// 更新すること。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 /utf-8 notification_tag_test.cpp notification_tag.cpp
//
// ⚠ `/utf-8` は必須 (#960)。下のベクタに `u8"ぷーざ@..."` の生マルチバイトが
// あり、CP932 環境で `/utf-8` 無しで叩くと MSVC がソースを CP932 と誤読して
// UTF-8 バイト列が変わり、multibyte ベクタだけ FAIL する。CMakeLists.txt /
// windows-release.yml も「/utf-8 必須」と明記している（出荷物の CI は正しい）。

#include <cstdio>
#include <string>

#include "notification_tag.h"

namespace {

int g_failures = 0;

void CheckEqU32(uint32_t got, uint32_t want, const char* name) {
  if (got == want) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s (got=%u want=%u)\n", name, got, want);
    ++g_failures;
  }
}

void CheckEqStr(const std::string& got, const std::string& want,
                const char* name) {
  if (got == want) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s (got=\"%s\" want=\"%s\")\n", name, got.c_str(),
                want.c_str());
    ++g_failures;
  }
}

void CheckTrue(bool cond, const char* name) {
  if (cond) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s\n", name);
    ++g_failures;
  }
}

}  // namespace

int main() {
  std::printf("NotificationTag tests\n");
  using capsicum::NotificationTagFor;
  using capsicum::NotificationTagKey;
  using capsicum::StableNotificationTag;

  // Dart 側と共有するテストベクタ。
  CheckEqU32(StableNotificationTag(""), 18652613u, "empty");
  CheckEqU32(StableNotificationTag("a"), 1678518572u, "single char");
  CheckEqU32(StableNotificationTag("pooza@mstdn.b-shock.org|123456"),
             70693920u, "account|id");
  // マルチバイト。UTF-8 バイト列に対して計算していることの確認（Dart 側の
  // utf8.encode と同じ結果になる保証）。ソースは UTF-8 で保存すること。
  CheckEqU32(StableNotificationTag(u8"ぷーざ@misskey.delmulin.com|9abc"),
             1901567813u, "multibyte");

  CheckTrue(StableNotificationTag("pooza@mstdn.b-shock.org|123456") !=
                StableNotificationTag("pooza@mstdn.b-shock.org|123457"),
            "different notification id");
  CheckTrue(StableNotificationTag("pooza@mstdn.b-shock.org|123456") !=
                StableNotificationTag("pooza@mstdn.delmulin.com|123456"),
            "different account");

  CheckEqStr(NotificationTagKey("pooza@mstdn.b-shock.org", "123456"),
             "pooza@mstdn.b-shock.org|123456", "tag key");
  // flutter_local_notifications が to_hstring(int) で作る Tag と同じ表現。
  CheckEqStr(NotificationTagFor("pooza@mstdn.b-shock.org", "123456"),
             "70693920", "tag string");

  // 通知 ID が無い払い出しでは Tag を付けない (#956)。付けると
  // hash("account|") が全通知で同一になり、OS が差し替え続けて Action Center
  // に最後の 1 件しか残らない。空 Tag は ShowRawToast が「付けない」と解釈する。
  CheckEqStr(NotificationTagFor("pooza@mstdn.b-shock.org", ""), "",
             "empty notification id yields no tag");
  // ⚠ NotificationTagKey は空に正規化しない。dedup レジストリのキーとして
  // 「キー無し」と区別できなくなるため（判断は wns_push.cpp の dedupable 側）。
  CheckEqStr(NotificationTagKey("pooza@mstdn.b-shock.org", ""),
             "pooza@mstdn.b-shock.org|", "tag key keeps the empty id");

  if (g_failures == 0) {
    std::printf("All tests passed\n");
    return 0;
  }
  std::printf("%d test(s) failed\n", g_failures);
  return 1;
}
