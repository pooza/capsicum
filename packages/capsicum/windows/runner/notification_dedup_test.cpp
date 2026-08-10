// notification_dedup.cpp のスタンドアロン単体テスト (#945)。
//
// 起動中に WNS 経路 (#474) と WebSocket 経路 (#569) が同じ通知を二重に出す件を、
// 「先に出した方が勝つ」レジストリで抑止する。#933 の Tag 畳み込みが実機で効かず
// （Tag / Group / AUMID は一致しているのに 2 通出る）、かつ Tag 方式では通知音の
// 重複を防げないため導入した。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 notification_dedup_test.cpp notification_dedup.cpp

#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "notification_dedup.h"

namespace {

int g_failures = 0;

void CheckTrue(bool cond, const char* name) {
  if (cond) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s\n", name);
    ++g_failures;
  }
}

void CheckEqSize(size_t got, size_t want, const char* name) {
  if (got == want) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s (got=%zu want=%zu)\n", name, got, want);
    ++g_failures;
  }
}

}  // namespace

int main() {
  std::printf("NotificationDedup tests\n");
  auto& registry = capsicum::NotificationDedupRegistry::Instance();

  registry.Reset();
  CheckTrue(!registry.WasShown("pooza@misskey.delmulin.com|abc"),
            "未登録のキーは未表示");

  registry.MarkShown("pooza@misskey.delmulin.com|abc");
  CheckTrue(registry.WasShown("pooza@misskey.delmulin.com|abc"),
            "登録したキーは表示済み");

  // 通知 ID が 1 文字違えば別の通知。畳んではいけない。
  CheckTrue(!registry.WasShown("pooza@misskey.delmulin.com|abd"),
            "別の通知 ID は巻き込まない");
  // 同じ通知 ID でもアカウントが違えば別の通知（複数垢ログイン時）。
  CheckTrue(!registry.WasShown("pooza@mstdn.b-shock.org|abc"),
            "別のアカウントは巻き込まない");

  // 空キーは「表示済み」にしない。native 側で account / notification_id を
  // 取り出せなかったときに、以降の通知が全部 dedup で消えるのを避ける。
  registry.Reset();
  registry.MarkShown("");
  CheckTrue(!registry.WasShown(""), "空キーは記録しない");
  CheckEqSize(registry.SizeForTesting(), 0, "空キーで件数が増えない");

  // 上限を超えたら全消しして再び貯め直す。取りこぼしても「二重に出る」だけで、
  // 通知を落とすより安全な側に倒す方針。
  registry.Reset();
  for (size_t i = 0; i < capsicum::NotificationDedupRegistry::kMaxKeys; ++i) {
    registry.MarkShown("k" + std::to_string(i));
  }
  CheckEqSize(registry.SizeForTesting(),
              capsicum::NotificationDedupRegistry::kMaxKeys, "上限まで貯まる");
  registry.MarkShown("overflow");
  CheckEqSize(registry.SizeForTesting(), 1, "上限超過で全消ししてから入れ直す");
  CheckTrue(registry.WasShown("overflow"), "全消し後も直近のキーは残る");

  // WNS 受信は MTA ワーカー、Dart からの addEmitted は UI スレッドで走るため、
  // 別スレッドから同時に叩かれる。データ競合で落ちないこと。
  registry.Reset();
  {
    std::vector<std::thread> threads;
    for (int t = 0; t < 4; ++t) {
      threads.emplace_back([&registry, t]() {
        for (int i = 0; i < 50; ++i) {
          const std::string key =
              "acct@example.test|" + std::to_string(t * 50 + i);
          registry.MarkShown(key);
          registry.WasShown(key);
        }
      });
    }
    for (auto& thread : threads) thread.join();
  }
  CheckEqSize(registry.SizeForTesting(), 200, "並行に入れても全件そろう");

  registry.Reset();
  CheckEqSize(registry.SizeForTesting(), 0, "Reset で空になる");

  if (g_failures == 0) {
    std::printf("All NotificationDedup tests passed\n");
    return 0;
  }
  std::printf("%d NotificationDedup test(s) failed\n", g_failures);
  return 1;
}
