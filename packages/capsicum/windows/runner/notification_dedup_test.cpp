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

  // 空キーは「表示済み」にしない。ただし**このガードは保険にすぎない**。
  // 呼び出し側が使う NotificationTagKey は `account + "|" + id` を返すので、
  // notification_id が空でもキーは空にならず、ここは発火しない。「id が
  // 取れなければ dedup を通さない」判断は wns_push.cpp の `dedupable` 側に
  // ある（#945）。ここを理由に呼び出し側のガードを外さないこと。
  registry.Reset();
  registry.MarkShown("");
  CheckTrue(!registry.WasShown(""), "空キーは記録しない");
  CheckEqSize(registry.SizeForTesting(), 0, "空キーで件数が増えない");

  // 上限を超えたら**最古から 1 件ずつ押し出す**（#995）。
  //
  // ⚠ **全消しに戻すと壊れる。** このレジストリは「もう出したか」の記録ではなく
  // 表示を抑止するかどうかを決める判定そのものなので、全消しの直後に遅れて
  // 届いた通知は「未出」と判定されて表示され、防いでいる二重表示が復活する。
  // Dart `BoundedKeySet` (#960) / macOS `BoundedKeySet` (#983) と同じ挙動。
  constexpr size_t kMax = capsicum::NotificationDedupRegistry::kMaxKeys;
  registry.Reset();
  for (size_t i = 0; i < kMax; ++i) {
    registry.MarkShown("k" + std::to_string(i));
  }
  CheckEqSize(registry.SizeForTesting(), kMax, "上限まで貯まる");
  CheckEqSize(registry.DroppedForTesting(), 0, "上限ちょうどでは押し出さない");
  CheckTrue(registry.WasShown("k0"), "上限ちょうどなら最古も残る");

  registry.MarkShown("overflow");
  CheckEqSize(registry.SizeForTesting(), kMax, "上限超過でも件数は上限のまま");
  CheckEqSize(registry.DroppedForTesting(), 1, "押し出したのは 1 件だけ");
  CheckTrue(!registry.WasShown("k0"), "最古の 1 件が押し出される");
  CheckTrue(registry.WasShown("k1"), "2 番目に古いキーは残る");
  CheckTrue(registry.WasShown("k" + std::to_string(kMax - 1)),
            "直前まで覚えていたキーは残る");
  CheckTrue(registry.WasShown("overflow"), "新しく入れたキーは残る");

  // ⚠ **LRU ではなく FIFO。** 既出キーを再び MarkShown しても押し出し順は
  // 動かさない。Dart の `LinkedHashSet` が再挿入で位置を変えないのに合わせる。
  // 片方だけ LRU にすると「同じキーなのに経路ごとに覚えている期間が違う」になる。
  registry.Reset();
  for (size_t i = 0; i < kMax; ++i) {
    registry.MarkShown("k" + std::to_string(i));
  }
  registry.MarkShown("k0");
  CheckEqSize(registry.SizeForTesting(), kMax, "既出キーの再登録で件数は増えない");
  registry.MarkShown("overflow");
  CheckTrue(!registry.WasShown("k0"),
            "既出キーを触っても押し出し順は変わらない (LRU にしない)");

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
  CheckEqSize(registry.DroppedForTesting(), 0, "Reset で押し出し件数も戻る");

  if (g_failures == 0) {
    std::printf("All NotificationDedup tests passed\n");
    return 0;
  }
  std::printf("%d NotificationDedup test(s) failed\n", g_failures);
  return 1;
}
