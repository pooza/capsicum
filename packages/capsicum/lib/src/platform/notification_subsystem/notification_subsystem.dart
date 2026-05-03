/// プラットフォーム差を吸収するローカル通知インターフェース (#330)。
///
/// 全プラットフォームで flutter_local_notifications を共通に使うが、
/// Android / Darwin (iOS+macOS) / Linux / Windows で必要な
/// `*NotificationDetails` の構築方法が異なる。本抽象が Details 構築を
/// 内部化することで、UI 層やプッシュ受信層は categorize した通知種別
/// (mention / dm 等) のみを意識すればよい設計に揃える。
abstract class NotificationSubsystem {
  /// プラグイン初期化と onTap ハンドラ登録。Android 13+ の通知権限要求も
  /// 内部で済ませる。複数回呼んでも安全（idempotent）。
  Future<void> initialize({void Function(String? payload)? onTap});

  /// 通知を表示する。`id` は同時に複数通知を並べるため呼び出し側で
  /// unique にする (例: タイムスタンプ ms 下位 32bit)。
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    NotificationCategory category = NotificationCategory.message,
  });

  /// iOS / macOS の通知許可ダイアログを明示的に出す。Android は
  /// initialize 内で要求済み、Linux / Windows は OS 設定に従う想定で
  /// 各プラットフォームの実装で no-op になる。
  Future<bool> requestPermission();
}

/// 通知の種別。今は単一カテゴリだが、将来の per-platform action set
/// (Mastodon メンションへの「返信」、Misskey メッセージへの「既読」等)
/// 拡張に備えて enum で持つ。
enum NotificationCategory { message, mention, dm }
