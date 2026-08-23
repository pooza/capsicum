// notification_dedup.cpp のスタンドアロン単体テスト (#945)。
//
// 起動中に WNS 経路 (#474) と WebSocket 経路 (#569) が同じ通知を二重に出す件を、
// 「先に出した方が勝つ」レジストリで抑止する。#933 の Tag 畳み込みが実機で効かず
// （Tag / Group / AUMID は一致しているのに 2 通出る）、かつ Tag 方式では通知音の
// 重複を防げないため導入した。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 notification_dedup_test.cpp notification_dedup.cpp

#include <atomic>
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

  // 表示権の原子的な取得 (#1014)。
  //
  // ⚠ **「WasShown で見てから MarkShown する」に戻すと、この節が守っている
  // ものが丸ごと消える。** 判定と記録が別々のロックになり、同じお知らせが
  // 同時に届くと両方が「未表示」を観測して両方がトーストを出す。
  registry.Reset();
  CheckTrue(registry.TryClaim("acct@example.test|claim"),
            "未表示なら表示権を取れる");
  CheckTrue(!registry.TryClaim("acct@example.test|claim"),
            "2 回目は表示権を取れない");
  CheckTrue(registry.WasShown("acct@example.test|claim"),
            "表示権を取ると表示済みになる");

  // 空キーは記録せず素通し。呼び出し側の `dedupable` が本来のガードで、
  // ここは保険（通知 ID が無いものは dedup を通さない = 最悪二重に出るだけ）。
  registry.Reset();
  CheckTrue(registry.TryClaim(""), "空キーは素通しする");
  CheckTrue(registry.TryClaim(""), "空キーは何度でも素通しする");
  CheckEqSize(registry.SizeForTesting(), 0, "空キーの claim で件数が増えない");

  // トーストを出せなかったときの巻き戻し。⚠ **claim を握ったままにすると
  // WebSocket 経路まで抑止され、その通知が 1 通も出なくなる。**
  registry.Reset();
  CheckTrue(registry.TryClaim("acct@example.test|rollback"), "claim できる");
  registry.ReleaseClaim("acct@example.test|rollback");
  CheckTrue(!registry.WasShown("acct@example.test|rollback"),
            "巻き戻すと未表示に戻る");
  CheckEqSize(registry.SizeForTesting(), 0, "巻き戻すと件数も戻る");
  CheckTrue(registry.TryClaim("acct@example.test|rollback"),
            "巻き戻した後はもう一度 claim できる");

  // 巻き戻しは順序列にも効く。ここが漏れると order_ に幽霊が残り、
  // 上限の押し出しが keys_ に無いキーを消そうとして件数が狂う。
  registry.Reset();
  registry.MarkShown("first");
  registry.TryClaim("second");
  registry.ReleaseClaim("second");
  registry.MarkShown("third");
  CheckEqSize(registry.SizeForTesting(), 2, "巻き戻したキーは順序列にも残らない");

  registry.ReleaseClaim("never-claimed");
  CheckEqSize(registry.SizeForTesting(), 2, "取っていない claim の返却は無害");

  // ⚠ **他経路が実際に表示していたら巻き戻さない** (#1015 Codex P2)。
  // WNS が claim を取ってから ShowRawToast が返るまでの間に、WebSocket 経路が
  // 同じ通知を出して addEmitted を撃つことがある。予約と表示済みを区別せずに
  // 消すと「出した」という記録まで消え、あとから届いた同じ通知が未出と判定
  // されて二重表示が復活する。
  registry.Reset();
  CheckTrue(registry.TryClaim("acct@example.test|both"), "WNS が予約する");
  registry.MarkShown("acct@example.test|both");  // WebSocket 経路が実際に表示。
  registry.ReleaseClaim("acct@example.test|both");  // WNS の表示は失敗した。
  CheckTrue(registry.WasShown("acct@example.test|both"),
            "表示済みへ昇格したキーは巻き戻らない");

  // 逆に、誰も表示していない予約はこれまでどおり取り消せる。
  registry.Reset();
  registry.TryClaim("acct@example.test|only-claimed");
  registry.ReleaseClaim("acct@example.test|only-claimed");
  CheckTrue(!registry.WasShown("acct@example.test|only-claimed"),
            "予約のままのキーは巻き戻る");

  // 押し出しは shown_ も道連れにする。残すと keys_ の部分集合という不変条件が
  // 崩れ、押し出したキーを二度と巻き戻せなくなる。
  registry.Reset();
  registry.MarkShown("shown-then-evicted");
  for (size_t i = 0; i < kMax; ++i) {
    registry.MarkShown("e" + std::to_string(i));
  }
  CheckTrue(!registry.WasShown("shown-then-evicted"),
            "表示済みでも上限超過なら押し出される");
  registry.TryClaim("shown-then-evicted");
  registry.ReleaseClaim("shown-then-evicted");
  CheckTrue(!registry.WasShown("shown-then-evicted"),
            "押し出し後に取り直した予約は巻き戻る (shown_ の残骸が無い)");

  // **本題**: 同じキーを同時に claim しても勝者は 1 つだけ。これが崩れると
  // 二重表示 + 通知音の重複になる（Windows は Tag が一致しても畳まない・#945）。
  registry.Reset();
  {
    std::atomic<int> winners{0};
    std::vector<std::thread> threads;
    for (int t = 0; t < 8; ++t) {
      threads.emplace_back([&registry, &winners]() {
        if (registry.TryClaim("acct@example.test|race")) ++winners;
      });
    }
    for (auto& thread : threads) thread.join();
    CheckEqSize(static_cast<size_t>(winners.load()), 1,
                "同じキーを同時に claim しても勝者は 1 つ");
  }
  CheckEqSize(registry.SizeForTesting(), 1, "勝者のぶんだけ記録される");

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
