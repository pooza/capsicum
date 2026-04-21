import 'dart:async';

/// アカウント単位のプッシュ通知登録の状態。
enum PushRegistrationState {
  /// 未着手・未観測（アプリ起動直後等）。
  idle,

  /// 登録処理中（HTTP 応答待ち等）。
  registering,

  /// 登録完了。
  registered,

  /// 失敗。[PushRegistrationSnapshot.reason] / [errorMessage] で内訳を保持。
  failed,

  /// サーバー側の仕様制約で登録不可（Misskey upstream の `secure: true` 等）。
  /// リトライしても成功しないので UI では「非対応」と表示する。
  notSupported,

  /// 明示的にスキップ（プリセットサーバー以外等）。UI 上は「対象外」扱い。
  skipped,
}

/// 失敗時の内訳。UI 側で表示文言・リトライ可否の判定に使う。
enum PushRegistrationFailureReason {
  /// 権限拒否（OS の通知権限がない）。
  permissionDenied,

  /// デバイストークン未取得（FCM / APNs 応答待ち or 失敗）。
  noDeviceToken,

  /// リレーサーバー登録が失敗。
  relayFailed,

  /// SNS 側サブスクリプション登録が失敗（Mastodon / Misskey）。
  subscribeFailed,

  /// その他・分類不能。
  unknown,
}

/// アカウント単位のプッシュ通知登録状態スナップショット。
///
/// UI（[push_notification_settings_screen]）と [PushRegistrationService] の
/// 内部イベント発火点で共有する。
class PushRegistrationSnapshot {
  const PushRegistrationSnapshot({
    required this.accountKey,
    required this.state,
    this.reason,
    this.errorMessage,
    this.updatedAt,
  });

  final String accountKey;
  final PushRegistrationState state;
  final PushRegistrationFailureReason? reason;
  final String? errorMessage;
  final DateTime? updatedAt;
}

/// プッシュ通知登録状態のグローバルストア。
///
/// [PushRegistrationService] が各フェーズで [update] を呼び、UI 側は
/// [snapshots] / [changes] を Provider 経由で購読する。
///
/// 状態はプロセスメモリ内に持つ（永続化不要。次回起動時の挙動は
/// [PushRegistrationService.registerAllAccounts] が書き直す）。
class PushRegistrationStatusStore {
  PushRegistrationStatusStore._();

  static final PushRegistrationStatusStore instance =
      PushRegistrationStatusStore._();

  final Map<String, PushRegistrationSnapshot> _snapshots = {};
  final StreamController<Map<String, PushRegistrationSnapshot>> _controller =
      StreamController.broadcast();

  Map<String, PushRegistrationSnapshot> get snapshots =>
      Map.unmodifiable(_snapshots);

  /// アカウント単位状態変更のストリーム。最新の全スナップショットを emit。
  Stream<Map<String, PushRegistrationSnapshot>> get changes =>
      _controller.stream;

  PushRegistrationSnapshot? get(String accountKey) => _snapshots[accountKey];

  void update(
    String accountKey,
    PushRegistrationState state, {
    PushRegistrationFailureReason? reason,
    String? errorMessage,
  }) {
    _snapshots[accountKey] = PushRegistrationSnapshot(
      accountKey: accountKey,
      state: state,
      reason: reason,
      errorMessage: errorMessage,
      updatedAt: DateTime.now(),
    );
    _controller.add(snapshots);
  }

  void remove(String accountKey) {
    if (_snapshots.remove(accountKey) != null) {
      _controller.add(snapshots);
    }
  }
}
