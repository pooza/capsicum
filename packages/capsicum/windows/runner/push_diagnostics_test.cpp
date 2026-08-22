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

  // 9) 表示失敗コードは正常系ではない (#957)。単一スロットでは異常系が温存
  //    されるため、後続の bgtask.shown に飲まれず warning のまま回収される。
  //    ここが benign 側に入ると「表示できていない」観測が info に沈む。
  {
    std::string a =
        BuildPushDiagnosticJson("", "bgtask.show_failed", "a.test", 10);
    std::string b = BuildPushDiagnosticJson(a, "bgtask.shown", "b.test", 20);
    PushDiagnostic d;
    ParsePushDiagnosticJson(b, &d);
    Check(d.code == "bgtask.show_failed" && d.at_ms == 10 &&
              d.host == "a.test" && d.count == 2,
          "bgtask.show_failed は後続の shown で上書きされない");

    // in-process 受信 (runner) が同じスロットへ書く経路も同様 (#957)。
    std::string c = BuildPushDiagnosticJson("", "wns.show_failed", "c.test", 30);
    std::string e = BuildPushDiagnosticJson(c, "bgtask.shown", "", 40);
    PushDiagnostic f;
    ParsePushDiagnosticJson(e, &f);
    Check(f.code == "wns.show_failed" && f.at_ms == 30 && f.host == "c.test",
          "wns.show_failed も正常系で上書きされない");
  }

  // 9b) お知らせ push の観測コード (#978)。表示成功は正常系（異常系を上書き
  //     しない）、表示失敗・本文欠落は異常系（後続の正常系に飲まれない）。
  {
    // 表示成功は正常系: 未消費の異常系を上書きしない。
    std::string a =
        BuildPushDiagnosticJson("", "bgtask.decrypt_failed", "a.test", 10);
    std::string b =
        BuildPushDiagnosticJson(a, "bgtask.announcement_shown", "b.test", 20);
    PushDiagnostic d;
    ParsePushDiagnosticJson(b, &d);
    Check(d.code == "bgtask.decrypt_failed" && d.at_ms == 10 && d.count == 2,
          "bgtask.announcement_shown は正常系（異常系を上書きしない）");

    // 表示失敗は異常系: 後続の正常系で上書きされず warning のまま回収される。
    std::string c = BuildPushDiagnosticJson(
        "", "bgtask.announcement_show_failed", "c.test", 30);
    std::string e = BuildPushDiagnosticJson(c, "bgtask.shown", "", 40);
    PushDiagnostic f;
    ParsePushDiagnosticJson(e, &f);
    Check(f.code == "bgtask.announcement_show_failed" && f.at_ms == 30 &&
              f.host == "c.test",
          "bgtask.announcement_show_failed は正常系で上書きされない");

    // relay が整形済み本文を載せていない状態も異常系（気付けないと
    // 「Windows だけお知らせが出ない」が手掛かり無しになる）。
    std::string g =
        BuildPushDiagnosticJson("", "bgtask.announcement_no_body", "g.test", 50);
    std::string h =
        BuildPushDiagnosticJson(g, "bgtask.announcement_shown", "", 60);
    PushDiagnostic i;
    ParsePushDiagnosticJson(h, &i);
    Check(i.code == "bgtask.announcement_no_body" && i.at_ms == 50,
          "bgtask.announcement_no_body は正常系で上書きされない");
  }

  // 9c) 起動中のお知らせ push の観測コード (#997)。bg task は Cancel されるので
  //     in-process が唯一の経路になる。分類の規律は 9b と同じで、**接頭辞だけ
  //     `wns.` に分ける**（bgtask の母数を濁さないため）。
  {
    // 表示成功は正常系。
    std::string a =
        BuildPushDiagnosticJson("", "bgtask.decrypt_failed", "a.test", 10);
    std::string b =
        BuildPushDiagnosticJson(a, "wns.announcement_shown", "b.test", 20);
    PushDiagnostic d;
    ParsePushDiagnosticJson(b, &d);
    Check(d.code == "bgtask.decrypt_failed" && d.at_ms == 10 && d.count == 2,
          "wns.announcement_shown は正常系（異常系を上書きしない）");

    // WebSocket 経路が先に出したので抑止した = 通常運転なので正常系。
    // ⚠ ここが異常系に分類されると、streaming が生きている**平常時の端末**が
    // 毎回 warning を上げ続けることになる（最も普通の結末なので）。
    std::string c =
        BuildPushDiagnosticJson("", "bgtask.no_keys", "c.test", 30);
    std::string e =
        BuildPushDiagnosticJson(c, "wns.announcement_deduped", "e.test", 40);
    PushDiagnostic f;
    ParsePushDiagnosticJson(e, &f);
    Check(f.code == "bgtask.no_keys" && f.at_ms == 30 && f.count == 2,
          "wns.announcement_deduped は正常系（異常系を上書きしない）");

    // 表示失敗・本文欠落・エンベロープ不正は異常系。
    for (const char* code :
         {"wns.announcement_show_failed", "wns.announcement_no_body",
          "wns.announcement_bad_payload"}) {
      std::string g = BuildPushDiagnosticJson("", code, "g.test", 50);
      std::string h =
          BuildPushDiagnosticJson(g, "wns.announcement_shown", "", 60);
      PushDiagnostic i;
      ParsePushDiagnosticJson(h, &i);
      const std::string label =
          std::string(code) + " は正常系で上書きされない";
      Check(i.code == code && i.at_ms == 50 && i.host == "g.test",
            label.c_str());
    }
  }

  // 10) 観測レコードの host は `username@host` の host 部分のみ（username は
  //     載せない、#800）。
  {
    using capsicum::PushDiagnosticHostFromAccount;
    Check(PushDiagnosticHostFromAccount("alice@mstdn.b-shock.org") ==
              "mstdn.b-shock.org",
          "username@host → host のみ");
    // ローカルパートに @ を含むアカウント表記でも、最後の @ で切る。
    Check(PushDiagnosticHostFromAccount("a@b@ex.test") == "ex.test",
          "@ が複数なら最後の @ 以降");
    Check(PushDiagnosticHostFromAccount("nohost").empty(),
          "@ 無し → 空（host 不明）");
    Check(PushDiagnosticHostFromAccount("trailing@").empty(),
          "@ が末尾 → 空（host 不明）");
    Check(PushDiagnosticHostFromAccount("").empty(), "空文字列 → 空");
  }

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
