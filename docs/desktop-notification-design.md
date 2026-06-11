# デスクトップ版 通知設計（WebSocket → OS ローカル通知）

## 位置付け

- 対象 OS: macOS / Linux / Windows の 3 OS 共通
- ネイティブ push (APNs / WNS) と**併存**する設計。本書はアプリ起動中の通知配信を担う中間解
- mobile / capsicum-relay 経路 ([pooza/capsicum-relay](https://github.com/pooza/capsicum-relay)、設計経緯は [archive/push-relay-plan.md](archive/push-relay-plan.md)) は別レイヤー。本書はアプリ起動中のデスクトップ通知配信を扱う

## 背景

デスクトップ 3 OS の現状 push 経路:

| OS | 配信経路 | 状態 |
|---|---|---|
| Linux | 全く無し（OS 標準の push 機構なし） | 完全に空 |
| macOS | APNs (+ capsicum-relay 拡張) | 未配線、#468 (v1.30 予定) |
| Windows | WNS (+ capsicum-relay 拡張) | 未配線、#474 (on-hold) |

3 OS とも「アプリ閉中の配信」は別途必要（→ #468 / #474）。一方で**アプリ起動中**は、Mastodon / Misskey の WebSocket streaming が既に通知 event を配信しているのに、現状の capsicum はこれを timeline 更新にしか使っていない。

本設計は **アプリ起動中の WebSocket streaming を OS ローカル通知 (libnotify / NSUserNotification / WinRT Toast) に流す経路** を 3 OS 共通で実装する。これにより:

- Linux: 唯一の通知配信手段として機能
- macOS / Windows: #468 / #474 完成までの暫定配信、完成後はネイティブ push と併存

## 設計

### コンポーネント全体図

```
┌──────────────────────────────────────────────────────────────┐
│ Adapter (Mastodon / Misskey)                                 │
│  ┌─────────────────────────────────────┐                     │
│  │ Existing: streamTimeline()           │ Stream<Post>        │
│  │  - WebSocket /streaming              │  → home_screen      │
│  └─────────────────────────────────────┘                     │
│  ┌─────────────────────────────────────┐                     │
│  │ NEW: streamNotifications()           │ Stream<Notification>│
│  │  - 別 WebSocket (長寿命)              │  → DesktopDispatcher│
│  └─────────────────────────────────────┘                     │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│ DesktopNotificationDispatcher (新規 service)                 │
│  - currentAdapterProvider を watch                            │
│  - adapter が NotificationStreamSupport なら subscribe        │
│  - 受信 Notification を NotificationSubsystem.show() へ      │
│  - dedup: 直近 N 件の notification.id を session-only set で管理│
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│ NotificationSubsystem (既存抽象、flutter_local_notifications) │
│  - Linux: libnotify                                          │
│  - macOS: NSUserNotification (Sandbox 下動作確認済み)         │
│  - Windows: WinRT Toast (MSIX 必須、#423 で整備済み)          │
└──────────────────────────────────────────────────────────────┘
```

### 1. NotificationStreamSupport mixin (capsicum_core)

```dart
// packages/capsicum_core/lib/src/social/interfaces/notification_stream_support.dart
abstract mixin class NotificationStreamSupport {
  /// 新規通知を発火するたびに emit するストリーム。
  /// 接続が切れた場合は内部で自動再接続を試み、上位には開いた状態のままに見せる。
  /// dispose 時にクローズ。複数 subscriber は broadcast 想定。
  Stream<Notification> streamNotifications();

  /// 通知ストリーミング接続をクローズ。アカウント切替時 / dispose 時に呼ぶ。
  void disposeNotificationStream();
}
```

`StreamSupport` (timeline 用) とは独立。adapter は両方 mix-in する想定。

### 2. MastodonStreaming 拡張

Mastodon の `user` stream は同一 WebSocket で複数 event を配信:

| event | 用途 | 現状 |
|---|---|---|
| `update` | 新規 post | streamTimeline で処理済み |
| `notification` | 新規通知 | **未処理** ← 本設計で処理 |
| `announcement` | 新規お知らせ | **未処理** (#476 が拾おうとしていた範囲) |
| `delete` | post 削除 | 未処理（本設計のスコープ外） |

実装方針: **既存 `MastodonStreaming` とは別に `MastodonNotificationStreaming` を新設**して、`stream=user` だが long-lived な専用 WebSocket を持つ。timeline streaming は home_screen の lifecycle に縛られているので、流用すると notification の発火タイミングが home_screen mount 中に限定されてしまうため別接続にする。

実装:
```dart
// packages/capsicum_backends/lib/src/mastodon/notification_streaming.dart
class MastodonNotificationStreaming {
  // 既存 MastodonStreaming と同じ reconnect / backoff を持つ
  // _onMessage:
  //   if event == 'notification':
  //     payload.toCapsicum() → controller.add(notification)
  //   if event == 'announcement':
  //     payload を Notification として変換し emit (NotificationType.announcement)
}
```

`MastodonAdapter` は `NotificationStreamSupport` を mix-in し、`streamNotifications()` で内部に `MastodonNotificationStreaming` を保持して `.connect()` の Stream を返す。

### 3. MisskeyStreaming 拡張

Misskey は WebSocket 内で複数 channel に subscribe する仕組み:

| channel | 用途 |
|---|---|
| `homeTimeline` / `localTimeline` / `hybridTimeline` / `globalTimeline` | timeline 更新（既存） |
| `main` | ユーザー個人の event（**notification**, follow, follow_request, etc.） |

`main` channel に subscribe して `body.type == 'notification'` を拾う。 timeline 用とは別接続で長寿命の `MisskeyNotificationStreaming` を新設。

```dart
// packages/capsicum_backends/lib/src/misskey/notification_streaming.dart
class MisskeyNotificationStreaming {
  // _connect:
  //   channel.sink.add({type: 'connect', body: {channel: 'main', id: ...}})
  // _onMessage:
  //   if json.type == 'channel' && body.type == 'notification':
  //     body.body.toCapsicum() → emit
}
```

### 4. DesktopNotificationDispatcher service

新規 service として `packages/capsicum/lib/src/service/desktop_notification_dispatcher.dart`。

```dart
class DesktopNotificationDispatcher {
  static bool get _isDesktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  StreamSubscription<Notification>? _sub;
  final Set<String> _emittedIds = {}; // セッション内 dedup

  void start(Ref ref) {
    if (!_isDesktop) return;
    // currentAdapterProvider の変化を listen
    ref.listen(currentAdapterProvider, (prev, next) {
      _sub?.cancel();
      _emittedIds.clear();
      if (next is NotificationStreamSupport) {
        _sub = (next as NotificationStreamSupport)
            .streamNotifications()
            .listen(_emit);
      }
    });
  }

  Future<void> _emit(Notification n) async {
    if (!_emittedIds.add(n.id)) return; // 既出
    final subsystem = ref.read(notificationSubsystemProvider);
    await subsystem.show(
      id: n.id.hashCode & 0x7FFFFFFF,
      title: _formatTitle(n),
      body: _formatBody(n),
      payload: jsonEncode({'account': ..., 'notificationId': n.id}),
      category: _categoryFor(n.type),
    );
  }
}
```

main.dart で desktop 起動時に `start()` を呼ぶ。

### 5. 重複排除 (dedup)

#468 (macOS APNs) / #474 (Windows WNS) が完成すると、**同じ通知を WebSocket 経由 + native push 経由の両方で受ける**可能性がある。重複排除の方針:

| シナリオ | 動作 |
|---|---|
| アプリ起動中、APNs と WebSocket の両方が到着 | 先に来た方を表示、後を `notification.id` で dedup |
| アプリ起動直後（cold start）に native push 由来の通知 ID が UserNotificationCenter に既存 | session-only set を再構築せず、最初に来た方を許可（多重表示の方が落とすより安全） |
| アカウント切替 | dispatcher が `_emittedIds.clear()` で session set をリセット |

#### macOS 横断 dedup の実装（#674、v1.36）

macOS 向けには上記方針を以下の経路で実装済み。キーは relay / NSE の account 表現に合わせた `username@host|notificationId`。

- **NSE → 通知への stamp**: `macos/CapsicumNotificationService` (#673) が復号した payload から通知 ID（Mastodon `notification_id` / Misskey `body.id`）を `userInfo["capsicum_notification_id"]` に stamp する
- **native 側 proxy**: `macos/Runner/NotificationDedupPlugin.swift` が flutter_local_notifications の UNUserNotificationCenter delegate を包み（FLN 由来は素通し）、remote push の willPresent を既出集合と突き合わせて後着を黙殺する
- **双方向 channel**: `net.shrieker.capsicum/notification_dedup`。WebSocket 先着は Dart → native `addEmitted`、APNs 先着は native → Dart `onRemotePresented` で `DesktopNotificationDispatcher` がスキップ

制約:

- willPresent はアプリ foreground 時のみ呼ばれる。macOS で「起動中だが非アクティブ」のときに呼ばれるかは文書上確定せず、**内部ベータの NSLog (`capsicum: dedup:`) で実測確認する**。呼ばれない場合、非アクティブ時の APNs banner は抑止できず、WebSocket 側スキップ（APNs 先着時）のみ効く
- stamp の無い remote（NSE 復号失敗の generic 文面）は dedup 不能のため foreground では黙殺する。従来 FLN delegate が非 FLN 通知の completionHandler を呼ばず foreground 表示されていなかった挙動の維持であり、同イベントは WebSocket 側がリッチ文面で出す見込みが高い

### 6. プラットフォーム別注記

#### Linux

- AppImage で `flutter_local_notifications_linux` (libnotify 経由) が動作 (#493 で plugin 登録の bug 解消済み)
- Sandbox 制約: なし（user session で動作するため）
- 既知の懸念: Wayland セッションで libnotify バックエンドが GTK 経由になる場合がある（GNOME / KDE どちらも対応）

#### macOS

- Sandbox 下で `NSUserNotification` が動作することは flutter_local_notifications 公式が保証
- Mac App Store ビルドの entitlements には追加変更不要 (`com.apple.security.network.client` だけで WebSocket は成立)
- 通知許可ダイアログは #404 で表示済み（push 未配線時代から）
- #468 (APNs) と併存: dedup 必須

#### Windows

- WinRT Toast 通知は MSIX 必須（#423 / v1.25 で整備済み）
- COM CLSID (`toast_activator.clsid`) との整合は `FlutterLocalNotificationSubsystem` 経由で既に通っている
- #474 (WNS) と併存: dedup 必須

### 7. エッジケース

| ケース | 想定挙動 |
|---|---|
| アプリ複数ウィンドウ起動 | 1 プロセスにつき 1 dispatcher。WebSocket も 1 接続 |
| 複数アカウント | 全ログインアカウントを並列 subscribe（#675）。dedup キーは `account\|notification.id` の複合、複数垢時は title 末尾に宛先ハンドルを添える。アクティブ垢の切替では既存購読を維持し増減のみ追従。当初実装はアクティブ垢のみだった |
| WebSocket 切断 | 既存 streaming の reconnect/backoff 機構を流用（最大 10 回、指数バックオフ） |
| アプリ起動直後にバックログ通知 | `user` stream は接続後の新規 event のみ emit するため空打ちなし |
| アカウント切替時の取り違え | アカウントごとに購読を `AccountKey` で同定し、dedup キーに account を含める（#675）。切替では購読を張り替えず維持 |
| 自分宛 mention を自分が投稿（誤発火懸念） | 既存通知抽象が type で fan-out しているため、Mastodon / Misskey 側で除外済み |

## 共存方針（将来 native push 完成時）

| フェーズ | 構成 |
|---|---|
| Phase A（本設計のみ実装後） | desktop 3 OS: WebSocket only |
| Phase B（#468 完成） | macOS: WebSocket + APNs。dedup 経路で 1 通知 1 表示 |
| Phase C（#474 完成） | Windows: WebSocket + WNS。dedup 経路で 1 通知 1 表示 |

native push が `_emittedIds` に追記してから OS 通知を表示すれば、後着の WebSocket は黙殺される。逆も同様。

## 実装フェーズ

1. **Phase 1**: capsicum_core の `NotificationStreamSupport` mixin 追加
2. **Phase 2**: `MastodonNotificationStreaming` 新設 + `MastodonAdapter` に mix-in
3. **Phase 3**: `MisskeyNotificationStreaming` 新設 + `MisskeyAdapter` に mix-in
4. **Phase 4**: `DesktopNotificationDispatcher` 新設 + main.dart で desktop 起動時に start
5. **Phase 5**: 動作検証（Linux 実機、macOS TestFlight、Windows Parallels VM）

Phase 1〜4 は依存関係上 1 PR にまとめるのが妥当。Phase 5 は内部ベータ経由 pooza 検証（OS ネイティブ機能変更ルールに従う）。

## 関連 issue

- #475 Linux push 方針決定（本設計で結論、close）
- #476 お知らせ通知 A 案 polling（本設計の announcement event 処理で実質代替、close 候補）
- #477 お知らせ通知 C 案 capsicum-relay（mobile 対象、存続）
- #468 macOS push 本配線（v1.34、本設計と併存）
- #474 Windows push 本配線（on-hold、本設計と併存）
- mobile / relay 経路の背景: [pooza/capsicum-relay](https://github.com/pooza/capsicum-relay) リポジトリ、初期設計は [archive/push-relay-plan.md](archive/push-relay-plan.md)
