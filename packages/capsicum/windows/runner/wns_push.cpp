#include "wns_push.h"

#include <winrt/Windows.ApplicationModel.Background.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.PushNotifications.h>
#include <winrt/Windows.Storage.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "local_state_files.h"
#include "notification_dedup.h"
#include "notification_tag.h"
#include "push_diagnostics.h"
#include "push_diagnostics_store.h"
#include "web_push_key_reader.h"
#include "web_push_receive.h"
#include "win_toast.h"

namespace {

using winrt::Windows::ApplicationModel::Background::BackgroundExecutionManager;
using winrt::Windows::ApplicationModel::Background::BackgroundTaskBuilder;
using winrt::Windows::ApplicationModel::Background::BackgroundTaskRegistration;
using winrt::Windows::ApplicationModel::Background::PushNotificationTrigger;
using winrt::Windows::Networking::PushNotifications::PushNotificationChannel;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationChannelManager;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationReceivedEventArgs;
using winrt::Windows::Networking::PushNotifications::PushNotificationType;

// バックグラウンドタスクの登録名と EntryPoint。push_background_task.cpp の
// ActivatableClassId・patch_appxmanifest_pushtask.ps1 の宣言と完全一致させる。
constexpr wchar_t kBackgroundTaskName[] = L"CapsicumPushTask";
constexpr wchar_t kBackgroundTaskEntryPoint[] =
    L"CapsicumPushTask.PushBackgroundTask";

// push_keys.json の truncate-write / 削除を直列化する。起動時同期と、ログアウト
// /登録後にメソッドチャネルから走る再同期が並走しても書き込みが交錯しないように
// するため。
std::mutex& PushKeysSyncMutex() {
  static std::mutex m;
  return m;
}

// ⚠ **パス組み立てと読み出しは local_state_files.h の共有実装へ寄せた
// (#976)。**同じ手続きが push_background_task.cpp / push_diagnostics_store.cpp
// と合わせて 3 箇所に写っていた。ファイル名を 1 箇所へ集めた (#764) 趣旨は、
// **writer と reader が別々に持つと片方だけ直したときに黙って壊れる**ことを
// 避けるためなので、その周りの手続きが割れているのでは意味が薄い。

// LocalState の push_keys.json 絶対パス。LocalFolder 解決失敗時は空文字列。
std::wstring PushKeysJsonPath() {
  return capsicum::LocalStateFilePath(capsicum::kLocalStateKeysetFile);
}

// push_labels.json 内容を読む（in-process 受信のラベル解決用、#770）。不在・空・
// 失敗時は空文字列を返し、呼び出し側は既定ラベルにフォールバックする。
std::string ReadPushLabelsJson() {
  return capsicum::ReadLocalStateFileUtf8(capsicum::kLocalStatePushLabelsFile);
}

// アプリ完全終了中の WNS raw 受信用バックグラウンドタスクを 1 度だけ登録する
// (#474 フェーズ C)。既存登録があればスキップ。MTA スレッドから呼ぶこと。
void RegisterPushBackgroundTaskOnce() {
  try {
    for (auto const& entry : BackgroundTaskRegistration::AllTasks()) {
      if (entry.Value().Name() == kBackgroundTaskName) {
        return;  // 既に登録済み。
      }
    }
    // パッケージ済みアプリのバックグラウンド実行許可（拒否されても登録は試みる）。
    BackgroundExecutionManager::RequestAccessAsync().get();
    BackgroundTaskBuilder builder;
    builder.Name(kBackgroundTaskName);
    builder.TaskEntryPoint(kBackgroundTaskEntryPoint);
    builder.SetTrigger(PushNotificationTrigger());
    builder.Register();
  } catch (...) {
    // 登録失敗（権限拒否・非パッケージ起動・マニフェスト未宣言等）は諦める。
    // 起動中は in-process 受信が動くため push 全体は止めない。
  }
}

// 起動中に WNS 経路がトーストを出したことを Dart へ伝えるコールバック (#945)。
// [RunWnsChannelReceiver] が購読開始前に 1 度だけ設定し、以降は受信ワーカー
// スレッドから呼ばれる。UI スレッドへの marshal は呼び出し側 (flutter_window)
// の責務。未設定（テスト・非 MSIX 起動）でも受信自体は動く。
std::mutex& PresentedCallbackMutex() {
  static std::mutex m;
  return m;
}

std::function<void(const std::string&)>& PresentedCallback() {
  static std::function<void(const std::string&)> callback;
  return callback;
}

void NotifyPresented(const std::string& key) {
  std::function<void(const std::string&)> callback;
  {
    std::lock_guard<std::mutex> lock(PresentedCallbackMutex());
    callback = PresentedCallback();
  }
  if (callback) callback(key);
}

// トーストを 1 通出すまでの結末。観測コードを撃ち分けるために区別する。
enum class ToastOutcome {
  // WebSocket 経路 (#569) が先に同じ通知を出していた。抑止は正常動作。
  kSuppressed,
  kShown,
  kShowFailed,
};

// dedup 判定 → トースト表示 → claim までを 1 本にまとめる。
//
// ⚠ **暗号化通知とお知らせで別々に書かない** (#997)。同じ形の写しが 2 つ並ぶと
// 片方だけ dedup を通し忘れる（#943 / #960 が繰り返し戒めている母数の欠け）。
// 呼び出し側の違いは「どの観測コードを書くか」だけに閉じる。
ToastOutcome ShowDedupedToast(const capsicum::PushDisplay& display) {
  // 起動中は WebSocket 経路 (#569) が同じ通知を先に出していることがある。
  // #933 は両経路のトースト Tag を揃えて OS に畳ませる方式だったが、**実機で
  // 畳まれないことが確認された** (#945)。Tag が畳めても 2 通目のトースト自体は
  // 作られるので通知音の重複は残る。よって macOS (#674) と同じ「先に出した方が
  // 勝つ」方式に寄せ、負けた側はトーストを作らない。
  //
  // ⚠ dedup できるのは通知 ID が取れたときだけ。NotificationTagKey は
  // `account + "|" + id` を返すので **id が空でもキーは空にならず**、
  // NotificationDedupRegistry 側の空キーガードは発火しない。id を持たない
  // payload が来ると全部が同じキーに潰れ、そのアカウント宛の 2 通目以降が
  // 黙って消える。**dedup を通さなければ最悪二重に出るだけ**なので、
  // 取れなかったときは素通しする方へ倒す。
  const bool dedupable = !display.notification_id.empty();
  const std::string dedup_key =
      dedupable ? capsicum::NotificationTagKey(display.account,
                                               display.notification_id)
                : std::string();
  // ⚠ **判定と記録を分けない** (#1014)。以前は「WasShown で見る → 出す →
  // MarkShown で記録する」の 3 段だったが、判定と記録が別々のロックなので
  // **同じお知らせが同時に届くと両方が「未表示」を観測して両方が出す**。
  // お知らせ (#978) は relay が WNS と WebSocket の双方へ流すため、まさに
  // この形で並行する。claim を取れなかった側は出さない。
  if (dedupable &&
      !capsicum::NotificationDedupRegistry::Instance().TryClaim(dedup_key)) {
    return ToastOutcome::kSuppressed;
  }
  // tag は #569 WebSocket 経路と同じ導出（`username@host|notificationId` の
  // 安定ハッシュ）のまま残す。dedup を取りこぼしたときの二段目の受け皿として、
  // OS 側の畳み込みに賭ける価値はある（効かない環境があるだけで害は無い）。
  // 通知 ID が無ければ NotificationTagFor が空文字を返し、Tag 無し＝畳まない
  // 挙動になる (#956)。上の dedupable と同じ前提で、別々に判断していない。
  // タップ遷移 (launch_arg) はフェーズ C で COM アクティベータと一緒に配線する
  // ため、ここでは付けない。
  // ⚠⚠ **claim を取った側が出しきる責任を負う (v1.60 レビュー)。**#1014 で
  // 判定を TryClaim へ前倒ししたぶん、**同じキーの他受信は既に「抑止」で
  // 帰っている**。ここで諦めて ReleaseClaim しても、戻ってくる相手はもう
  // 居ないので**トーストが 1 通も出ない**。このレジストリは
  // 「取りこぼすなら二重表示の側へ倒す」設計（notification_dedup.h）なので、
  // この経路だけ「消える側」へ倒れるのは筋が通らない。1 回だけ出し直す。
  //
  // ⚠ **これでも窓は閉じきらない。**2 回とも失敗すれば結局出ない。完全に
  // 塞ぐには抑止側を待たせる必要があり、そこまでの複雑さは持ち込まない。
  auto show = [&] {
    return capsicum::ShowRawToast(
        display.title, display.body, /*launch_arg=*/"",
        capsicum::NotificationTagFor(display.account, display.notification_id));
  };
  if (!show() && !show()) {
    // 表示できなかったので取った claim を返す。⚠ **握りつぶすと WebSocket
    // 経路まで抑止されて通知が 1 通も出なくなる**（#1014 で claim を前倒しに
    // したぶん、この巻き戻しが必須になった）。NotifyPresented も通さない。
    if (dedupable) {
      capsicum::NotificationDedupRegistry::Instance().ReleaseClaim(dedup_key);
    }
    return ToastOutcome::kShowFailed;
  }
  if (dedupable) {
    // 予約を「表示済み」へ昇格させる。以降このキーは ReleaseClaim で取り消せ
    // なくなる（#1015 Codex P2 — 予約と表示済みを区別する理由は
    // notification_dedup.h の ReleaseClaim の注記）。
    capsicum::NotificationDedupRegistry::Instance().MarkShown(dedup_key);
    NotifyPresented(dedup_key);
  }
  return ToastOutcome::kShown;
}

// TryBuildAnnouncementDisplay の error 文字列を観測コードへ写す (#997)。
// "not an announcement" は暗号化経路へ回るだけなのでここには来ない。
//
// ⚠ **`bgtask.` 系と同じコードに合流させない。**「`bgtask.*` が無ければ bg task
// 未起動」というトリアージ規則 (push_diagnostics.h) は bg task の母数の上で
// 成り立っており、bg task を Cancel して走る in-process の件数を混ぜると濁る。
// 既存の `wns.show_failed` に倣って `wns.` 系で撃つ。
std::string AnnouncementDiagnosticCodeForError(const std::string& error) {
  // announcement_body が空。⚠ **原因を relay の版だと断定しない** (#982)。
  // 本文が空文字のお知らせ（画像だけ・装飾だけ）でも同じコードになる。
  if (error == "missing announcement body") {
    return "wns.announcement_no_body";
  }
  // invalid envelope / missing account。
  return "wns.announcement_bad_payload";
}

// 無暗号化のお知らせ push (#978) を起動中に表示する (#997)。announcement で
// なければ false を返し、呼び出し側が暗号化経路へ回す。
//
// **起動中の受信ハンドラは bg task を `args.Cancel(true)` で止めている**ので、
// ここが唯一の処理経路になる。#978 までは `HandleWnsRawPayload`（暗号化専用）
// しか呼んでおらず、お知らせは表示も観測もされずに捨てられていた。
//
// ⚠ **「WebSocket 経路 (#569) が出すから in-process は表示不要」ではない。**
// streaming が落ちている間はお知らせが 1 通も出なくなる。まさにその保険として
// WNS 経路がある。二重表示は [ShowDedupedToast] の dedup が防ぐ（WebSocket 側と
// 同じ `announcement:<id>` キーで claim し合う）。
bool HandleAnnouncementContent(const std::string& content) {
  capsicum::PushDisplay announcement;
  std::string error;
  if (!capsicum::TryBuildAnnouncementDisplay(content, &announcement, &error)) {
    if (error == "not an announcement") {
      return false;  // 暗号化通知。復号経路へ。
    }
    // announcement を名乗っているのに表示材料が足りない。暗号化経路へ回しても
    // "not an encrypted notification" になるだけで理由が消えるので、ここで
    // 専用コードとして残す。
    capsicum::RecordPushDiagnostic(
        AnnouncementDiagnosticCodeForError(error),
        capsicum::PushDiagnosticHostFromAccount(announcement.account));
    return true;
  }
  const std::string host =
      capsicum::PushDiagnosticHostFromAccount(announcement.account);
  switch (ShowDedupedToast(announcement)) {
    case ToastOutcome::kShown:
      capsicum::RecordPushDiagnostic("wns.announcement_shown", host);
      break;
    case ToastOutcome::kShowFailed:
      capsicum::RecordPushDiagnostic("wns.announcement_show_failed", host);
      break;
    case ToastOutcome::kSuppressed:
      // WebSocket 経路が先に出した通常運転。⚠ **ここも記録する。** 無記録だと
      // 「お知らせが出ない」報告に対して *WNS raw push がそもそも端末へ届いて
      // いたのか* が分からず、relay / WNS / streaming のどこを見るかが決まらない
      // （#997 の「観測が空白」はこの穴も含む）。正常系なので info 扱い。
      capsicum::RecordPushDiagnostic("wns.announcement_deduped", host);
      break;
  }
  return true;
}

// 起動中に受けた「本文を落とされた通知」(capsicum-relay#65) を待ってから
// 判断する時間。WebSocket 経路 (#569) は通常 relay → WNS より先に着くが、
// 前後どちらもありうるので、着いてから少し待ってから証拠を見る。
constexpr int64_t kDegradedGraceMs = 8000;
// 着く前のどこまでを「同じ通知を WebSocket が出した」証拠とみなすか。
constexpr int64_t kDegradedLookbackMs = 30000;

// 起動中に受けた本文なしの通知を、WebSocket 経路が生きていれば出さず、
// 生きている証拠が無ければ汎用文面で出す。
//
// ⚠⚠ **「起動中は出さない」と決め打ちしてはいけない**（Codex P1 / PR #1169）。
// 起動中の受信は `args.Cancel(true)` で bg task を止めているので、ここで捨てると
// **WebSocket が切れている間（再接続を諦めた状態を含む）その通知がどこにも
// 出ない**。一方、通知 ID を持たないのでキー単位の dedup は効かず、毎回出すと
// WebSocket の本文付きトーストと 2 通並ぶ。
//
// そこで「同じアカウント宛を WebSocket が前後に出したか」を生きている証拠に
// する（`addEmitted` で記録）。無関係の通知で抑止する取り違えはありうるが、
// その時点で WebSocket は生きているので本来の通知も WebSocket から届く。
//
// 待つ間に受信スレッドを塞がないよう detached スレッドで回す。
//
// ⚠ **待っている間にアプリが閉じられても消さない**（Codex P2 / PR #1169）。
// detached スレッドはプロセス終了で打ち切られ、bg task も Cancel 済みなので
// 引き継ぎ手がいない。待機中のものは [PendingDegraded] に置き、終了時に
// [FlushPendingDegradedNotifications] が引き取る。**先に取った側だけが処理する**
// （[TakePendingDegraded]）ので、待機明けと終了が重なっても二重に出ない。
struct PendingDegradedItem {
  capsicum::PushDisplay display;
  int64_t arrived_ms = 0;
};

std::mutex& PendingDegradedMutex() {
  static std::mutex m;
  return m;
}

std::map<uint64_t, PendingDegradedItem>& PendingDegraded() {
  static std::map<uint64_t, PendingDegradedItem> pending;
  return pending;
}

// [id] の待機分を取り出す。既に誰かが取っていれば false。
bool TakePendingDegraded(uint64_t id, PendingDegradedItem* out) {
  std::lock_guard<std::mutex> lock(PendingDegradedMutex());
  auto& pending = PendingDegraded();
  const auto it = pending.find(id);
  if (it == pending.end()) return false;
  *out = it->second;
  pending.erase(it);
  return true;
}

// 待機明け / 終了時の共通の判断と表示・観測。⚠ **呼び出し側が MTA を張った
// まま呼ぶこと**（Codex P2 / PR #1169）。トーストの表示だけでなく、観測の記録
// (`RecordPushDiagnostic` → `LocalStateFilePath` → `ApplicationData::Current`) も
// WinRT を呼ぶので、apartment を畳んでから記録すると黙って落ちる。
void ResolveDegraded(const PendingDegradedItem& item) {
  const std::string host =
      capsicum::PushDiagnosticHostFromAccount(item.display.account);
  if (capsicum::NotificationDedupRegistry::Instance().StreamEmittedSince(
          item.display.account, item.arrived_ms - kDegradedLookbackMs)) {
    // WebSocket 経路が本文付きで出している通常運転（正常系）。
    capsicum::RecordPushDiagnostic("wns.degraded_skipped", host);
    return;
  }
  bool shown = false;
  try {
    // 通知 ID を持たないので Tag は付けない (#956)。
    shown = capsicum::ShowRawToast(item.display.title, item.display.body,
                                   /*launch_arg=*/"", /*tag=*/std::string());
  } catch (...) {
    shown = false;
  }
  capsicum::RecordPushDiagnostic(
      shown ? "wns.degraded_shown" : "wns.degraded_show_failed", host);
}

// MTA をスレッドの寿命いっぱいに張る。flutter_window.cpp の worker と同じく、
// 既に別の apartment が張られていて失敗したときは張らずに進む。
class ScopedMtaApartment {
 public:
  ScopedMtaApartment() {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      initialized_ = true;
    } catch (...) {
      initialized_ = false;
    }
  }
  ~ScopedMtaApartment() {
    if (initialized_) winrt::uninit_apartment();
  }
  ScopedMtaApartment(const ScopedMtaApartment&) = delete;
  ScopedMtaApartment& operator=(const ScopedMtaApartment&) = delete;

 private:
  bool initialized_ = false;
};

void HandleDegradedInProcess(const capsicum::PushDisplay& degraded) {
  static std::atomic<uint64_t> next_id{1};
  const uint64_t id = next_id.fetch_add(1);
  {
    std::lock_guard<std::mutex> lock(PendingDegradedMutex());
    PendingDegraded()[id] =
        PendingDegradedItem{degraded, capsicum::DedupClockNowMs()};
  }
  std::thread([id]() {
    ScopedMtaApartment apartment;
    std::this_thread::sleep_for(std::chrono::milliseconds(kDegradedGraceMs));
    PendingDegradedItem item;
    // 終了時の flush が先に引き取っていれば何もしない。
    if (!TakePendingDegraded(id, &item)) return;
    ResolveDegraded(item);
  }).detach();
}

// raw 通知 1 通を表示する。お知らせ (#978・無暗号化) を先に見て、それ以外を
// 暗号化通知として復号する。**判定順は bg task (push_background_task.cpp) と
// 同じ**に保つ — 片方だけ順序を変えると、観測コードの意味が経路ごとにずれる。
//
// ⚠ **暗号化側は観測の粒度をお知らせと揃えていない。意図的な非対称。**
// 復号失敗（鍵不在等）も dedup による抑止も、従来どおり無記録で捨てる。
// #997 の範囲がお知らせに閉じているからだけでなく、**件数の桁が違う**ため:
// 通知 push は 1 日に何十通も来るので、抑止や `no push keys`（ログアウト直後の
// アカウント宛など定常的に出る）を毎回書くと単一スロットの代表イベントがそれで
// 埋まり、拾いたい異常が埋もれる。お知らせは月に数通なので書いてよい。
// 揃えたくなったら、まず単一スロットをやめる設計から始めること。
void DisplayRawNotification(const std::string& content) {
  if (HandleAnnouncementContent(content)) {
    return;
  }
  // relay が 5000B 超過で本文を落とした通知 (capsicum-relay#65)。判断は
  // [HandleDegradedInProcess] で少し待ってから行う。
  {
    capsicum::PushDisplay degraded;
    std::string error;
    if (capsicum::TryBuildDegradedDisplay(content, &degraded, &error)) {
      HandleDegradedInProcess(degraded);
      return;
    }
  }
  capsicum::PushDisplay display;
  // アカウント別 reblog/post ラベル（リノート / リキュア！等）を LocalState の
  // push_labels.json から引く (#770)。無ければ既定（ブースト / 投稿）に倒れる。
  const std::string labels = ReadPushLabelsJson();
  if (!capsicum::HandleWnsRawPayload(
          content, capsicum::DefaultSecureStorageDatPath(), &display, nullptr,
          labels)) {
    return;
  }
  if (ShowDedupedToast(display) == ToastOutcome::kShowFailed) {
    // 復号までは通ったのに表示できなかった。無記録だと**無言で落ちる**ため、
    // bg task と同じ LocalState スロットへ観測を残す (#957)。ここが空白だと
    // 「WNS は届いているのに通知が出ない」の切り分けが手掛かり無しになる。
    // 記録は次回起動時に runner が回収して Sentry へ上げる。
    capsicum::RecordPushDiagnostic(
        "wns.show_failed",
        capsicum::PushDiagnosticHostFromAccount(display.account));
  }
}

}  // namespace

// push 鍵セットを AppContainer のバックグラウンドタスクが読める LocalState に
// 書き出す (#474 フェーズ C / Option A)。bg task はサンドボックスのため
// ローミング %APPDATA% の flutter_secure_storage.dat を読めず DPAPI 復号も
// できないので、FullTrust 本体がここで鍵セットだけを平文 JSON 化して
// ApplicationData.LocalFolder（パッケージ専有・両者からアクセス可）へ渡す。
//
// 起動時に加えてログアウト・アカウント追加など鍵セット変更後にも呼ばれる
// （flutter_window の syncPushKeys メソッドチャネル経由）。鍵セットが読めない
// （.dat 不在・DPAPI 失敗）ときは push_keys.json を削除し、ログアウト済み
// アカウントの平文鍵を bg task に残さない（鍵が読めない＝通知が出ない安全側に
// 倒す。他プラットフォームが secure storage から鍵を消すと復号できなくなるのと
// parity を取る）。
void SyncWnsPushKeysToLocalState() {
  std::lock_guard<std::mutex> guard(PushKeysSyncMutex());
  try {
    const std::wstring path = PushKeysJsonPath();
    if (path.empty()) {
      return;  // LocalFolder 解決不可。次の機会に再同期される。
    }
    const std::wstring dat = capsicum::DefaultSecureStorageDatPath();
    std::string json;
    if (!capsicum::ExtractPushKeysetMapJson(dat, &json, nullptr)) {
      // .dat 不在・DPAPI 失敗・パース失敗。古い平文鍵を残さないよう既存ファイルを
      // 消す。通常ログアウト（鍵エントリのみ削除）は .dat が読めて空マップ "{}" が
      // 返るため、この分岐ではなく下の truncate-write 側で正しく上書きされる。
      _wremove(path.c_str());
      return;
    }
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (f) {
      f.write(json.data(), static_cast<std::streamsize>(json.size()));
    }
  } catch (...) {
    // 書き出し失敗は致命でない（in-process 受信は引き続き動く）。
  }
}

void SyncWnsPushLabelsToLocalState(const std::string& labels_json) {
  // push_keys とは別ファイルなので独立した mutex で書き込みを直列化する。
  static std::mutex labels_mutex;
  std::lock_guard<std::mutex> guard(labels_mutex);
  try {
    const std::wstring path =
        capsicum::LocalStateFilePath(capsicum::kLocalStatePushLabelsFile);
    if (path.empty()) {
      return;  // LocalFolder 解決不可。次の機会に再同期される。
    }
    if (labels_json.empty()) {
      // ログイン中アカウントが無い等。古いラベルを残さず削除する（読めなければ
      // 既定ラベルにフォールバックするので安全側）。
      _wremove(path.c_str());
      return;
    }
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (f) {
      f.write(labels_json.data(),
              static_cast<std::streamsize>(labels_json.size()));
    }
  } catch (...) {
    // 書き出し失敗は致命でない（既定ラベルで表示は続く）。
  }
}

void FlushPendingDegradedNotifications() {
  std::vector<PendingDegradedItem> items;
  {
    std::lock_guard<std::mutex> lock(PendingDegradedMutex());
    for (auto& entry : PendingDegraded()) items.push_back(entry.second);
    PendingDegraded().clear();
  }
  if (items.empty()) return;
  // 終了時は待たずに判断する（WebSocket の証拠がその時点で揃っていれば抑止、
  // 無ければ出す）。main スレッドは STA なので、MTA を張った別スレッドで
  // 処理して join する（待機中のスレッドと同じ条件で WinRT を呼ぶため）。
  std::thread([items = std::move(items)]() {
    ScopedMtaApartment apartment;
    for (const auto& item : items) ResolveDegraded(item);
  }).join();
}

void RunWnsChannelReceiver(
    const std::function<void(const std::string&)>& on_uri,
    const std::function<void(const std::string&)>& on_presented) {
  {
    // 購読を張る前に設定する。張った後だと最初の 1 通を取りこぼしうる。
    std::lock_guard<std::mutex> lock(PresentedCallbackMutex());
    PresentedCallback() = on_presented;
  }
  PushNotificationChannel channel{nullptr};
  try {
    // .get() でブロックするため MTA。CreatePushNotificationChannelForApplication-
    // Async はパッケージ ID を持つ起動でのみ成功し、既存チャンネルがあれば即座に
    // 返る（初回 / 期限切れ更新時のみネットワークが走る）。
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    channel = PushNotificationChannelManager::
                  CreatePushNotificationChannelForApplicationAsync()
                      .get();
  } catch (...) {
    // 非 MSIX 起動（パッケージ ID 無し）・ネットワーク不通・WinRT 例外。
  }

  std::string uri;
  if (channel) {
    try {
      uri = winrt::to_string(channel.Uri());
    } catch (...) {
      uri.clear();
    }
  }
  // URI を呼び出し側へ返す（空 = 取得不可。Dart 側で noDeviceToken 扱い）。
  on_uri(uri);

  if (!channel) {
    winrt::uninit_apartment();
    return;
  }

  // アプリ完全終了中の受信用に鍵を AppContainer から読める LocalState に同期して
  // から、バックグラウンドタスクを登録する (#474 フェーズ C)。順序が逆だと
  // 「登録済みだが鍵未同期」の窓で push を受けて bgtask.no_keyset を偽陽性で
  // 記録しうるため、同期を先に済ませる。なお初回起動時は Dart の鍵生成がまだ
  // 走っていないことがあり、その分はログイン/登録完了後に Dart が syncPushKeys
  // メソッドチャネルで再同期する（ログアウト時の鍵削除も同経路）。起動中は下の
  // in-process 受信が args.Cancel(true) でこのタスク発火を抑止する。
  SyncWnsPushKeysToLocalState();
  RegisterPushBackgroundTaskOnce();

  // 起動中の in-process 受信を購読する。raw 通知は OS が自動表示しないため、
  // 自前で復号 → トースト表示する。
  try {
    channel.PushNotificationReceived(
        [](const PushNotificationChannel&,
           const PushNotificationReceivedEventArgs& args) {
          try {
            if (args.NotificationType() == PushNotificationType::Raw) {
              // 起動中に受けたら自前表示し、OS のバックグラウンドタスク発火
              // （フェーズ C）を抑止して二重処理を防ぐ。
              args.Cancel(true);
              DisplayRawNotification(
                  winrt::to_string(args.RawNotification().Content()));
            }
          } catch (...) {
            // 受信ハンドラ内の例外は握り潰す（プロセスを巻き込まない）。
          }
        });
  } catch (...) {
    winrt::uninit_apartment();
    return;
  }

  // channel と MTA アパートメントを保持したままブロックし、購読を生かし続ける
  // （イベントは MTA の RPC スレッドで発火するためメッセージポンプは不要）。
  std::mutex wait_mutex;
  std::condition_variable wait_cv;
  std::unique_lock<std::mutex> wait_lock(wait_mutex);
  wait_cv.wait(wait_lock, [] { return false; });
}

bool ConsumePushDiagnosticsJson(std::string* out_json) {
  if (out_json == nullptr) {
    return false;
  }
  out_json->clear();
  try {
    // パス組み立てと読み出しは共有実装へ (#976)。⚠ **消すのはこちらの責務**
    // （読んだら消す = 二重送信の防止）なので、パスは別に持つ。
    const std::wstring path =
        capsicum::LocalStateFilePath(capsicum::kLocalStateDiagFile);
    if (path.empty()) {
      return false;  // 非 MSIX 起動。
    }
    *out_json = capsicum::ReadFileUtf8(path);
    // 二重送信を避けるため読み出したら消す。⚠ **空でも消す** — 0 バイトの
    // 残骸を置いておくと、次回起動でも同じ判定を繰り返す。
    _wremove(path.c_str());
    return !out_json->empty();
  } catch (...) {
    out_json->clear();
    return false;
  }
}
