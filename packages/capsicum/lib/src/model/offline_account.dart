import 'account_key.dart';

/// [OfflineAccount] が `Account` へ昇格できていない理由 (#967)。
///
/// **復帰の手段が違うので区別する。**到達不能は待てば戻るが、secret 消失は
/// 待っても戻らず、ユーザーがログインし直すしかない。同じグレー表示のまま
/// 混ぜると「待っていれば直るのか、自分が何かするのか」が読めない。
enum OfflineAccountReason {
  /// サーバーが停止 / 再構築中などで probe が通らない (#792)。secret は残って
  /// いるので、背景リトライでいずれ `Account` へ昇格する。
  unreachable,

  /// secure storage 側の secret だけが消えている (#967)。再インストール / データ
  /// 削除 / 端末復元・機種変 / OS 由来の Keystore リセット、および設定の
  /// インポート（アクセストークンを持ち込まない設計・#857）で起きる。
  ///
  /// ⚠ **背景リトライでは戻らない。**トークンが無いので probe すら組み立てられ
  /// ない。UI はログインへ送る。
  secretMissing,
}

/// オンライン復元できていないログイン済みアカウントの軽量表現 (#792 / #967)。
///
/// `Account`（`user` / `adapter` / `userSecret` がいずれも非 null 必須で、多くの
/// widget が `account.user` を参照する）とは**別表現**として保持し、切替 UI に
/// greyed 表示する。従来はこの状態のアカウントが一覧から丸ごと消え、「サーバー
/// ごと存在しないように」見えていた。
///
/// ⚠ **`Account` に寄せない**のが設計の要点 (#967)。adapter もトークンも無いので、
/// タイムライン取得・push 登録・投げ銭判定など `Account` を要求する処理はどれも
/// 実行できない。`List<Account>` の消費側を union 型や nullable 化で触ると、
/// 「未接続なら何もしない」判断が全消費側へ散る。ここに置けば消費側は無変更で
/// 済む。
///
/// identity は [AccountKey] の host/username から引く（profile キャッシュは
/// follow-up）。
class OfflineAccount {
  final AccountKey key;

  /// 昇格できていない理由。復帰導線の出し分けに使う。
  final OfflineAccountReason reason;

  /// いま probe が走っているか (#938 で意味が変わった)。
  ///
  /// #792 では「背景 backoff がまだ残っている」で、使い切ると恒久的に false ＝
  /// 「もう自動では戻らない」の印だった。背景再試行が打ち切りを持たなくなった
  /// ので、いまは**この瞬間 probe 中か**を表す。false は「諦めた」ではなく
  /// 周回の合間。UI の「再試行中…」/「接続を待っています」がこの粒度。
  ///
  /// ⚠ [OfflineAccountReason.secretMissing] では**常に false**。probe を組み
  /// 立てられないので「再試行中」はありえない。
  final bool retrying;

  const OfflineAccount({
    required this.key,
    this.reason = OfflineAccountReason.unreachable,
    this.retrying = true,
  });

  /// secret が消えたアカウント (#967)。背景リトライの対象外なので
  /// [retrying] は立てない。
  const OfflineAccount.secretMissing({required this.key})
    : reason = OfflineAccountReason.secretMissing,
      retrying = false;

  OfflineAccount copyWith({bool? retrying}) => OfflineAccount(
    key: key,
    reason: reason,
    retrying: retrying ?? this.retrying,
  );

  /// 背景リトライで自動的に戻りうるか。false ならユーザーの操作が要る。
  bool get recoverableByRetry => reason == OfflineAccountReason.unreachable;

  /// 切替 UI 用の `@username@host` ラベル（profile 不在でも表示できる）。
  String get handle => '@${key.username}@${key.host}';
}
