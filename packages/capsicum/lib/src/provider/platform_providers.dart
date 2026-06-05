import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/background_task/background_task_scheduler.dart';
import '../platform/background_task/background_task_scheduler_factory.dart';
import '../platform/media_picker/media_picker.dart';
import '../platform/media_picker/media_picker_factory.dart';
import '../platform/notification_subsystem/notification_subsystem.dart';
import '../platform/now_playing/now_playing_provider_factory.dart';
import '../platform/now_playing/now_playing_resolver.dart';
import '../service/notification_init.dart';

/// プラットフォーム抽象層 (`lib/src/platform/`) の Riverpod 入口。
/// UI 層はこの provider 経由で実装を受け取り、`Platform.isXxx` を
/// 直接参照しない (CLAUDE.md デスクトップ対応 設計指針)。

/// メディア選択 ([MediaPicker])。iOS / Android / macOS は image_picker、
/// Linux / Windows は file_selector を使う。
final mediaPickerProvider = Provider<MediaPicker>((_) => createMediaPicker());

/// ローカル通知 ([NotificationSubsystem])。flutter_local_notifications を
/// 共通基盤として使い、プラットフォーム差は実装内部で吸収する。バックグラウンド
/// isolate からも同じインスタンスを参照する必要があるため、`notification_init`
/// の top-level singleton をそのまま返す。
final notificationSubsystemProvider = Provider<NotificationSubsystem>(
  (_) => notificationSubsystem,
);

/// バックグラウンドタスク ([BackgroundTaskScheduler])。モバイルはプッシュ
/// 通知リレーに一本化済みで no-op、デスクトップは Timer 常駐ベースで動く。
/// v1.23 では interface のみ提供で、実際の利用は v1.24 のデスクトップ着手時。
final backgroundTaskSchedulerProvider = Provider<BackgroundTaskScheduler>(
  (_) => createBackgroundTaskScheduler(),
);

/// プレイヤー横断ナウプレ取得 ([NowPlayingResolver], #466)。優先順位つきで
/// 取得源を合成する。リストは**優先順位の高い順**:
///
///   1. Spotify 源（#570、mulukhiya 経由・OS 非依存）— 後続増分で先頭に追加
///   2. OS ネイティブ源（Linux MPRIS / Windows SMTC。それ以外は no-op）
///
/// 現状は OS ネイティブ源のみ。Spotify provider が入ったら、その availability
/// （アカウントの Spotify 連携状態）に応じてここで先頭に prepend する。
final nowPlayingResolverProvider = Provider<NowPlayingResolver>(
  (_) => NowPlayingResolver([createNativeNowPlayingProvider()]),
);
