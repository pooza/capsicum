// push_diagnostics.cpp のスタンドアロン単体テスト (#474 フェーズ C 観測)。
//
// 単一スロット JSON の組み立て（count の累積・最新イベント上書き・host 任意）と
// 解析（空 / 不正 / 前方互換）を検証する。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 push_diagnostics_test.cpp push_diagnostics.cpp

#include <cstdio>
#include <string>

#include "push_diagnostics.h"

namespace {

int g_failures = 0;

void Check(bool cond, const char* name) {
  if (cond) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s\n", name);
    ++g_failures;
  }
}

}  // namespace

int main() {
  std::printf("PushDiagnostics tests\n");
  using capsicum::BuildPushDiagnosticJson;
  using capsicum::ParsePushDiagnosticJson;
  using capsicum::PushDiagnostic;

  // 1) 空 prev からの初回イベント。count=1。
  {
    std::string j = BuildPushDiagnosticJson("", "bgtask.shown", "ex.test", 1000);
    PushDiagnostic d;
    bool ok = ParsePushDiagnosticJson(j, &d);
    Check(ok && d.code == "bgtask.shown" && d.count == 1 && d.at_ms == 1000 &&
              d.host == "ex.test",
          "初回イベント count=1 / フィールド round-trip");
  }

  // 2) 既存スロットへの累積。count=prev+1、最新の code/at/host で上書き。
  {
    std::string prev =
        BuildPushDiagnosticJson("", "bgtask.shown", "a.test", 1000);
    std::string j =
        BuildPushDiagnosticJson(prev, "bgtask.decrypt_failed", "", 2000);
    PushDiagnostic d;
    bool ok = ParsePushDiagnosticJson(j, &d);
    Check(ok && d.code == "bgtask.decrypt_failed" && d.count == 2 &&
              d.at_ms == 2000 && d.host.empty(),
          "累積 count=2 / 最新で上書き / host 省略");
  }

  // 3) 3 回累積する。count は常に進むが、未消費の異常系（no_keys）は後続の
  //    正常系（shown）で上書きされず温存される。
  {
    std::string p1 = BuildPushDiagnosticJson("", "bgtask.shown", "", 1);
    std::string p2 = BuildPushDiagnosticJson(p1, "bgtask.no_keys", "", 2);
    std::string p3 = BuildPushDiagnosticJson(p2, "bgtask.shown", "h", 3);
    PushDiagnostic d;
    ParsePushDiagnosticJson(p3, &d);
    Check(d.count == 3 && d.code == "bgtask.no_keys" && d.at_ms == 2,
          "3 回累積 count=3 / 異常系は正常系で上書きされない");
  }

  // 4) 空文字列 / 空オブジェクト / 壊れた JSON はレコード無し。
  {
    PushDiagnostic d;
    Check(!ParsePushDiagnosticJson("", &d), "空文字列 → レコード無し");
    Check(!ParsePushDiagnosticJson("{}", &d), "空オブジェクト → レコード無し");
    Check(!ParsePushDiagnosticJson("{garbage", &d), "壊れた JSON → レコード無し");
  }

  // 5) 壊れた prev からの build は count=1 で復帰する。
  {
    std::string j = BuildPushDiagnosticJson("{bad", "bgtask.shown", "", 5);
    PushDiagnostic d;
    bool ok = ParsePushDiagnosticJson(j, &d);
    Check(ok && d.count == 1, "壊れた prev → count=1 で復帰");
  }

  // 6) 未知キーを含む JSON も前方互換で解析できる。
  {
    std::string j =
        "{\"code\":\"bgtask.shown\",\"future\":\"x\",\"count\":7,"
        "\"at_ms\":9,\"extra\":42}";
    PushDiagnostic d;
    bool ok = ParsePushDiagnosticJson(j, &d);
    Check(ok && d.code == "bgtask.shown" && d.count == 7 && d.at_ms == 9,
          "未知キーを読み飛ばして解析");
  }

  // 7) host に特殊文字（引用符）が来てもエスケープ往復する。
  {
    std::string j = BuildPushDiagnosticJson("", "bgtask.shown", "a\"b", 1);
    PushDiagnostic d;
    bool ok = ParsePushDiagnosticJson(j, &d);
    Check(ok && d.host == "a\"b", "host のエスケープ往復");
  }

  // 8) 異常系の上書きルール（単一スロットで warning を温存する）。
  {
    // 正常系 → 異常系: 異常系で上書きする（最新の異常を記録）。
    std::string a = BuildPushDiagnosticJson("", "bgtask.shown", "h1", 10);
    std::string b = BuildPushDiagnosticJson(a, "bgtask.decrypt_failed", "", 20);
    PushDiagnostic d;
    ParsePushDiagnosticJson(b, &d);
    Check(d.code == "bgtask.decrypt_failed" && d.count == 2 && d.at_ms == 20,
          "正常系 → 異常系は上書きする");

    // 異常系 → 正常系: 異常系を温存する（code/at/host は据え置き・count のみ進む）。
    std::string c =
        BuildPushDiagnosticJson(b, "bgtask.shown", "h3", 30);
    PushDiagnostic e;
    ParsePushDiagnosticJson(c, &e);
    Check(e.code == "bgtask.decrypt_failed" && e.count == 3 && e.at_ms == 20 &&
              e.host.empty(),
          "異常系 → 正常系は温存する（count のみ進む）");

    // 異常系 → 別の異常系: 最新の異常系で上書きする。
    std::string f =
        BuildPushDiagnosticJson(c, "bgtask.exception", "", 40);
    PushDiagnostic g;
    ParsePushDiagnosticJson(f, &g);
    Check(g.code == "bgtask.exception" && g.count == 4 && g.at_ms == 40,
          "異常系 → 別の異常系は最新で上書きする");
  }

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
