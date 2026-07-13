import 'account_key.dart';

/// 到達不能でオンライン復元できていないログイン済みアカウントの軽量表現
/// (#792)。
///
/// サーバー停止 / 再構築中でセッション復元 probe が失敗しても、secret は
/// secure storage に残っている。従来はこの状態のアカウントが一覧から丸ごと
/// 消え「サーバーごと存在しないように」見えた。`Account`（`user` 必須で多くの
/// widget が `account.user` を参照する）とは別表現として保持し、切替 UI に
/// greyed 表示しつつ背景リトライで自動的にオンライン (`Account`) へ昇格させる。
///
/// identity は [AccountKey] の host/username から引く（profile キャッシュは
/// follow-up）。
class OfflineAccount {
  final AccountKey key;

  /// 背景リトライがまだ継続中か。false は backoff を尽くしても復帰しなかった
  /// （手動再試行は可能）。
  final bool retrying;

  const OfflineAccount({required this.key, this.retrying = true});

  OfflineAccount copyWith({bool? retrying}) =>
      OfflineAccount(key: key, retrying: retrying ?? this.retrying);

  /// 切替 UI 用の `@username@host` ラベル（profile 不在でも表示できる）。
  String get handle => '@${key.username}@${key.host}';
}
