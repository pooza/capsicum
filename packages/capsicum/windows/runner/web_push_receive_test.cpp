// web_push_receive.cpp のスタンドアロン単体テスト (#474 フェーズ2)。
//
// 「raw エンベロープ → 鍵読み → 復号 → 文面化」のオーケストレーション配線を、
// RFC 8291 Appendix A の既知ベクタ（鍵 + 暗号文 body）で検証する。鍵は DPAPI で
// 保護した flutter_secure_storage.dat に入れ、暗号文 body はエンベロープ JSON に
// 包んで HandleWnsRawPayload に渡す。
//
// 復号は成功するが Appendix A の平文（"When I grow up, ..."）は SNS の JSON では
// ないため、最終段の payload パースで停止する。これにより「エンベロープ解析 →
// 鍵 lookup → base64url → 復号（鍵と body が一致しないと GCM タグで失敗する）」
// までの配線が通っていることを段階別エラーで確認する。改竄 body は「復号段」で
// 失敗することと対比させ、復号配線が本当に動いていることを示す。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 web_push_receive_test.cpp web_push_receive.cpp ^
//      web_push_key_reader.cpp web_push_decrypt.cpp web_push_payload.cpp ^
//      web_push_text_util.cpp notification_type_label.cpp ^
//      /link crypt32.lib bcrypt.lib shell32.lib ole32.lib version.lib

#include <windows.h>
#include <dpapi.h>

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "web_push_receive.h"

namespace {

int g_failures = 0;

void CheckErr(bool ok, const std::string& err, const char* want_err,
              const char* name) {
  bool pass = !ok && err == want_err;
  if (pass) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s (ok=%d err=\"%s\" want=\"%s\")\n", name, ok ? 1 : 0,
                err.c_str(), want_err);
    ++g_failures;
  }
}

std::string JsonStr(const std::string& s) {
  std::string out = "\"";
  for (char c : s) {
    if (c == '"' || c == '\\') out.push_back('\\');
    out.push_back(c);
  }
  out += "\"";
  return out;
}

void WriteBytes(const std::wstring& path, const uint8_t* data, size_t len) {
  std::ofstream fs(path, std::ios::binary | std::ios::trunc);
  if (fs && len > 0) {
    fs.write(reinterpret_cast<const char*>(data),
             static_cast<std::streamsize>(len));
  }
}

bool WriteDat(const std::wstring& path, const std::string& json) {
  DATA_BLOB in;
  in.cbData = static_cast<DWORD>(json.size());
  in.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(json.data()));
  DATA_BLOB out = {0, nullptr};
  if (!CryptProtectData(&in, L"capsicum-test", nullptr, nullptr, nullptr, 0,
                        &out)) {
    return false;
  }
  WriteBytes(path, out.pbData, out.cbData);
  LocalFree(out.pbData);
  return true;
}

std::wstring TempPath(const wchar_t* name) {
  wchar_t dir[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, dir);
  std::wstring base = (n > 0 && n < MAX_PATH) ? std::wstring(dir) : L".\\";
  return base + name;
}

// RFC 8291 Appendix A の UA 鍵 + 暗号文 body（web_push_decrypt のテストと同値）。
const char* kP256dh =
    "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP"
    "js7Vd8pZGH6SRpkNtoIAiw4";
const char* kAuth = "BTBZMqHH6r4Tts7J_aSIgg";
const char* kPriv = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94";
const char* kBody =
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
    "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
    "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";

const char* kAccount = "probe@example.test";

std::string KeysetJson() {
  return "{" + JsonStr("p256dh") + ":" + JsonStr(kP256dh) + "," +
         JsonStr("auth") + ":" + JsonStr(kAuth) + "," + JsonStr("priv") + ":" +
         JsonStr(kPriv) + "}";
}

std::string DatJson() {
  return "{" + JsonStr(std::string("capsicum_push_keyset_mastodon://") +
                       kAccount) +
         ":" + JsonStr(KeysetJson()) + "}";
}

std::string Envelope(const std::string& account, const std::string& encoding,
                     const std::string& body) {
  std::string out = "{";
  out += JsonStr("account") + ":" + JsonStr(account) + ",";
  out += JsonStr("server") + ":" + JsonStr("https://example.test") + ",";
  if (!encoding.empty()) out += JsonStr("encoding") + ":" + JsonStr(encoding) + ",";
  out += JsonStr("body") + ":" + JsonStr(body);
  out += "}";
  return out;
}

void CheckEq(const std::string& got, const std::string& want,
             const char* name) {
  if (got == want) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s (got=\"%s\" want=\"%s\")\n", name, got.c_str(),
                want.c_str());
    ++g_failures;
  }
}

// capsicum-relay の AnnouncementWorker#build_payload が組み立てる無暗号化
// エンベロープ (#477 / #978)。空文字列のフィールドは載せない（旧 relay を
// 模す）。
std::string AnnouncementEnvelope(const std::string& account,
                                 const std::string& announcement_id,
                                 const std::string& announcement_body) {
  std::string out = "{";
  out += JsonStr("notification_type") + ":" + JsonStr("announcement") + ",";
  out += JsonStr("server") + ":" + JsonStr("example.test") + ",";
  if (!announcement_id.empty()) {
    out += JsonStr("announcement_id") + ":" + JsonStr(announcement_id) + ",";
  }
  // HTML のままの本文。C++ 側はこれを**使わない**ことをテストで固定する。
  out += JsonStr("announcement_content") + ":" +
         JsonStr("<p>raw <b>html</b> body</p>") + ",";
  if (!announcement_body.empty()) {
    out +=
        JsonStr("announcement_body") + ":" + JsonStr(announcement_body) + ",";
  }
  out += JsonStr("announcement_published_at") + ":" +
         JsonStr("2026-08-16T00:00:00Z") + ",";
  out += JsonStr("account") + ":" + JsonStr(account);
  out += "}";
  return out;
}

}  // namespace

int main() {
  std::printf("WebPushReceive (orchestration) tests\n");
  using capsicum::HandleWnsRawPayload;
  using capsicum::PushDisplay;

  std::wstring dat = TempPath(L"capsicum_recv_test.dat");
  if (!WriteDat(dat, DatJson())) {
    std::fprintf(stderr, "failed to write test .dat\n");
    return 2;
  }

  // 1) フル配線: エンベロープ → 鍵 → base64url → 復号 まで通る。Appendix A の
  //    平文は JSON でないため最終段 payload パースで停止する（= 復号は成功）。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope(kAccount, "aes128gcm", kBody), dat,
                                  &d, &err);
    CheckErr(ok, err, "payload parse failed",
             "復号配線が通る（平文非JSONで parse 段停止 = 復号成功）");
  }

  // 2) account 欠落。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope("", "aes128gcm", kBody), dat, &d, &err);
    CheckErr(ok, err, "missing account", "account 欠落");
  }

  // 3) 暗号化通知でない（encoding 無し）→ 呼び出し側に委ねる。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope(kAccount, "", kBody), dat, &d, &err);
    CheckErr(ok, err, "not an encrypted notification",
             "encoding 無しは encrypted でない扱い");
  }

  // 4) 改竄 body → 復号段で失敗（1 と対比し復号が実際に走っていることを示す）。
  {
    std::string tampered = kBody;
    tampered[tampered.size() - 1] =
        (tampered.back() == 'A') ? 'B' : 'A';  // 末尾 1 文字を変える。
    PushDisplay d;
    std::string err;
    bool ok =
        HandleWnsRawPayload(Envelope(kAccount, "aes128gcm", tampered), dat, &d, &err);
    CheckErr(ok, err, "decryption failed", "改竄 body は復号段で失敗");
  }

  // 5) .dat に鍵が無いアカウント。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(
        Envelope("other@nope.test", "aes128gcm", kBody), dat, &d, &err);
    CheckErr(ok, err, "no push keys", "鍵不在アカウント");
  }

  // 6) body の base64 が不正。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope(kAccount, "aes128gcm", "!!!not base64!!!"),
                                  dat, &d, &err);
    CheckErr(ok, err, "invalid body base64url", "body base64 不正");
  }

  // 7) エンベロープ JSON が壊れている。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload("{not json", dat, &d, &err);
    CheckErr(ok, err, "invalid envelope", "壊れたエンベロープ");
  }

  // 8) 復号できない形式 → unsupported encoding。#800: 復号前に account を out へ
  //    載せ、失敗パスでも host を観測に出せることを確認する。
  //    ⚠ aesgcm は capsicum#1390 から復号する（8b）ので、ここでは未知の形式を使う。
  {
    PushDisplay d;
    std::string err;
    bool ok =
        HandleWnsRawPayload(Envelope(kAccount, "gzip", kBody), dat, &d, &err);
    CheckErr(ok, err, "unsupported encoding", "未知の encoding は unsupported");
    if (d.account == kAccount) {
      std::printf("  ok   - unsupported encoding でも account が観測に載る (#800)\n");
    } else {
      std::printf(
          "  FAIL - unsupported encoding で account 未設定 (got=\"%s\")\n",
          d.account.c_str());
      ++g_failures;
    }
  }

  // 8b) aesgcm は unsupported にしない（capsicum#1390）。crypto_key /
  //     encryption の無いエンベロープは、復号へ進んで失敗する。復号そのものの
  //     正否は web_push_decrypt_test.cpp が見る。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope(kAccount, "aesgcm", kBody), dat, &d,
                                  &err);
    CheckErr(ok, err, "decryption failed",
             "aesgcm は復号へ進む（ヘッダが無ければ復号の失敗）");
    // 復号の失敗でも encoding が観測に載る (#1403)。aes128gcm の鍵不一致（4）と
    // 同じ "decryption failed" になるので、これが無いと見分けられない。
    CheckEq(d.encoding, "aesgcm", "aesgcm の復号失敗で encoding が観測に載る");
  }

  // 8c) aes128gcm の復号失敗にも encoding が載る（8b との対・#1403）。
  {
    std::string tampered = kBody;
    tampered[tampered.size() - 1] = (tampered.back() == 'A') ? 'B' : 'A';
    PushDisplay d;
    std::string err;
    HandleWnsRawPayload(Envelope(kAccount, "aes128gcm", tampered), dat, &d,
                        &err);
    CheckEq(d.encoding, "aes128gcm",
            "aes128gcm の復号失敗で encoding が観測に載る");
  }

  // 8d) 観測 JSON を壊しうる encoding は "invalid" に丸める (#1403)。
  {
    PushDisplay d;
    std::string err;
    HandleWnsRawPayload(Envelope(kAccount, "x\"y", kBody), dat, &d, &err);
    CheckEq(d.encoding, "invalid", "記号を含む encoding は invalid に丸める");
  }

  // ---- 無暗号化のお知らせ push (#978) ----
  using capsicum::TryBuildAnnouncementDisplay;

  // 「お知らせ」の UTF-8 期待値（このテストは /utf-8 なしでコンパイルするため
  //  日本語リテラルは \xHH で書く。notification_type_label_test と同じ流儀）。
  const std::string kAnnouncementLabel =
      "\xe3\x81\x8a\xe7\x9f\xa5\xe3\x82\x89\xe3\x81\x9b";  // お知らせ

  // 9) 正常系: relay が整形した本文をそのまま使い、title は統一ラベルに解決。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = TryBuildAnnouncementDisplay(
        AnnouncementEnvelope(kAccount, "42", "SUMMARIZED BODY"), &d, &err);
    if (ok) {
      std::printf("  ok   - お知らせエンベロープを受理する\n");
    } else {
      std::printf("  FAIL - お知らせエンベロープを受理しない (err=\"%s\")\n",
                  err.c_str());
      ++g_failures;
    }
    CheckEq(d.title, kAnnouncementLabel, "title は統一ラベル「お知らせ」");
    CheckEq(d.body, "SUMMARIZED BODY",
            "body は relay の整形済み本文をそのまま（HTML を使わない）");
    CheckEq(d.type, "announcement", "type は announcement");
    CheckEq(d.account, kAccount, "account を観測用に載せる");
    // #569 の notification_streaming.dart が作る Notification.id と同じ表現。
    // ここがズレると起動直後の streaming 通知と Tag が揃わず OS が畳めない。
    CheckEq(d.notification_id, "announcement:42",
            "notification_id は WebSocket 経路と同じ announcement:<id>");
  }

  // 10) 暗号化通知のエンベロープは announcement 経路に入らない（呼び出し側が
  //     復号経路へ回す合図）。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = TryBuildAnnouncementDisplay(
        Envelope(kAccount, "aes128gcm", kBody), &d, &err);
    CheckErr(ok, err, "not an announcement",
             "暗号化エンベロープは announcement でない");
  }

  // 11) relay が announcement_body を載せていない（Phase 2 より古い relay）。
  //     announcement_content (HTML) に倒して空トーストを出すのではなく、
  //     観測へ落とす。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = TryBuildAnnouncementDisplay(
        AnnouncementEnvelope(kAccount, "42", ""), &d, &err);
    CheckErr(ok, err, "missing announcement body",
             "整形済み本文が無ければ表示しない（HTML に倒さない）");
  }

  // 12) account 欠落。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok =
        TryBuildAnnouncementDisplay(AnnouncementEnvelope("", "42", "SUMMARIZED BODY"), &d,
                                    &err);
    CheckErr(ok, err, "missing account", "お知らせでも account は必須");
  }

  // 13) announcement_id が無ければ Tag を付けない (#956)。付けると id を持た
  //     ないお知らせが全部同じ Tag へ潰れ、最後の 1 件しか残らない。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok =
        TryBuildAnnouncementDisplay(AnnouncementEnvelope(kAccount, "", "SUMMARIZED BODY"),
                                    &d, &err);
    if (ok && d.notification_id.empty()) {
      std::printf("  ok   - id 無しのお知らせは notification_id を空にする\n");
    } else {
      std::printf(
          "  FAIL - id 無しで notification_id が空でない (ok=%d got=\"%s\")\n",
          ok ? 1 : 0, d.notification_id.c_str());
      ++g_failures;
    }
  }

  // 14) 壊れたエンベロープ。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = TryBuildAnnouncementDisplay("{not json", &d, &err);
    CheckErr(ok, err, "invalid envelope", "壊れたお知らせエンベロープ");
  }

  // 15) 逆向きの固定: お知らせを **暗号化経路に渡しても表示材料にならない**。
  //     起動中の in-process 受信 (wns_push.cpp) はこの関数しか呼ばないので、
  //     お知らせは WebSocket 経路 (#569) だけが出す＝二重に出ない。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(
        AnnouncementEnvelope(kAccount, "42", "SUMMARIZED BODY"), dat, &d, &err);
    CheckErr(ok, err, "not an encrypted notification",
             "お知らせは暗号化経路では表示されない（起動中の二重表示防止）");
  }

  // ---- 本文を落とされた通知 (capsicum-relay#65) ----
  // relay の WnsClient#degraded_payload が組み立てる形。値はすべて文字列
  // （ParseFlatObject は文字列以外の値を含むエンベロープを丸ごと捨てる）。
  const std::string degraded_envelope =
      "{" + JsonStr("server") + ":" + JsonStr("https://example.test") + "," +
      JsonStr("account") + ":" + JsonStr(kAccount) + "," + JsonStr("degraded") +
      ":" + JsonStr("1") + "}";

  // 16) 汎用文面を作る。文面は Android の fallback / relay の APNs degrade と同じ。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = TryBuildDegradedDisplay(degraded_envelope, &d, &err);
    if (ok) {
      std::printf("  ok   - degrade エンベロープを受理する\n");
    } else {
      std::printf("  FAIL - degrade エンベロープを受理しない (err=\"%s\")\n",
                  err.c_str());
      ++g_failures;
    }
    CheckEq(d.title, "capsicum", "title は capsicum");
    CheckEq(d.body,
            std::string(kAccount) +
                " \xe3\x81\xab\xe9\x80\x9a\xe7\x9f\xa5\xe3\x81\x8c\xe3\x81\x82"
                "\xe3\x82\x8a\xe3\x81\xbe\xe3\x81\x99",
            "本文は「<account> に通知があります」");
    CheckEq(d.account, kAccount, "account を載せる（観測の host に使う）");
    CheckEq(d.notification_id, "", "notification_id は空（Tag を付けない #956）");
  }

  // 17) ⚠⚠ 本丸の逆向き: degrade エンベロープは**暗号化経路では何も出ない**。
  //     #65 以前は bg task がここへ回して黙って捨てていた。bg task / 起動中の
  //     どちらも、暗号化経路より先に TryBuildDegradedDisplay を通すこと。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(degraded_envelope, dat, &d, &err);
    CheckErr(ok, err, "not an encrypted notification",
             "degrade は暗号化経路では表示材料にならない（専用の判定が要る）");
  }

  // 18) 普通の暗号化通知は degrade と取り違えない。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = TryBuildDegradedDisplay(Envelope(kAccount, "aes128gcm", kBody),
                                      &d, &err);
    CheckErr(ok, err, "not degraded", "暗号化通知は degrade ではない");
  }

  // 19) 目印があっても暗号化 body を持つなら復号できる方を優先する。
  {
    capsicum::PushDisplay d;
    std::string err;
    std::string env = Envelope(kAccount, "aes128gcm", kBody);
    env.insert(env.size() - 1, "," + JsonStr("degraded") + ":" + JsonStr("1"));
    bool ok = TryBuildDegradedDisplay(env, &d, &err);
    CheckErr(ok, err, "not degraded", "body を持つなら目印があっても復号側へ");
  }

  // 20) お知らせも degrade と取り違えない（目印を持たない）。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = TryBuildDegradedDisplay(
        AnnouncementEnvelope(kAccount, "42", "SUMMARIZED BODY"), &d, &err);
    CheckErr(ok, err, "not degraded", "お知らせは degrade ではない");
  }

  // 21) 目印はあるが account が無い。
  {
    capsicum::PushDisplay d;
    std::string err;
    bool ok = TryBuildDegradedDisplay(
        "{" + JsonStr("degraded") + ":" + JsonStr("1") + "}", &d, &err);
    CheckErr(ok, err, "missing account", "degrade でも account は必須");
  }

  // ---- 見出しに宛先を添える (#1412・#1407 の Windows 分) ----
  // push_labels.json の予約キー "_multi_account" を Dart が載せたときだけ添える。
  using capsicum::TitleWithRecipient;
  const std::string labels_single =
      "{" + JsonStr(kAccount) + ":" +
      JsonStr("{\"reblog\":\"RB\",\"post\":\"PO\"}") + "}";
  const std::string labels_multi =
      "{" + JsonStr(kAccount) + ":" +
      JsonStr("{\"reblog\":\"RB\",\"post\":\"PO\"}") + "," +
      JsonStr("_multi_account") + ":" + JsonStr("1") + "}";

  // 22) 1 アカウント（写しはあるが予約キーが無い）なら添えない。
  CheckEq(TitleWithRecipient("Title", kAccount, labels_single), "Title",
          "1 アカウントなら見出しに宛先を添えない");

  // 23) 複数アカウントなら `見出し (@user@host)`。
  CheckEq(TitleWithRecipient("Title", kAccount, labels_multi),
          "Title (@" + std::string(kAccount) + ")",
          "複数アカウントなら見出しに宛先を添える");

  // 24) 写しが無い（push_labels.json 不在 = 空）なら添えない（従来どおり）。
  CheckEq(TitleWithRecipient("Title", kAccount, ""), "Title",
          "写しが無ければ見出しに宛先を添えない");

  _wremove(dat.c_str());

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
