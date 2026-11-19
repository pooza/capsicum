/// 未接続アカウント (#967) の表示と導線を 1 箇所に集める (#1012)。
///
/// ⚠ **同じ文言と同じ URL が、ドロワーの切替リストとオフラインホームの
/// 2 箇所にベタ書きされていた。** 文言を直すときに片方だけ直ると、同じ状態を
/// 指す言い方が画面ごとに割れる。`post_scope_display.dart` と同じ「文字列
/// リテラルを散らさず中央集約した定数を参照する」方針（`docs/CLAUDE.md` の
/// 「用語統一」節）。
library;

import '../../model/account_key.dart';

/// 未接続アカウントの行に出す説明。タップで接続し直せることまで含める。
const disconnectedAccountSubtitle = '未接続（タップで接続し直す）';

/// 接続し直すためのログイン画面の行き先。
///
/// ⚠ **ホストを埋めて開く。**移行直後にホスト名を打ち直させない（#967 の
/// 「接続し直す」導線の要）。
///
/// ⚠ **文字列連結ではなく [Uri] で組む。**`AccountKey.host` の性質上ルートの
/// 差し替えにはならないが、クエリの組み立てを手書きしていると、あとで別の
/// パラメータを足したときにエンコードを忘れる。
String reconnectRouteFor(AccountKey key) =>
    Uri(path: '/server', queryParameters: {'host': key.host}).toString();

/// オフラインホーム (#792) の見出しと本文。
typedef OfflineHomeCopy = ({String title, String heading, String body});

/// オフラインホームの見出しと本文を、オフラインになった理由で出し分ける。
///
/// ⚠⚠ **キーリングが原因と分かっているときは、オフラインの説明を出さない
/// (#1393)。**以前は赤い枠だけが「ログイン情報を読み出せません」と言い、見出しと
/// 本文は「接続できません」「端末がオフラインか、サーバーが停止中の可能性」の
/// ままだった。原因が 2 つ並んで見え、利用者はネットワークやサーバーを疑う。
/// キーリングが読めないとトークンを読む前に止まるので、「再試行で戻る」側の
/// アカウントがオフラインなのは、そのときキーリングのせいと決まる。
///
/// - [allNeedLogin]: 全件が未接続（トークンが無い・#967）。キーリングより優先
///   する（待っても戻らないので、接続し直しへ促す）
/// - [keyringUnavailable] / [keyringLocked]: `SecureStorageHealth` の旗
///
/// ⚠ 原因と次の一手の詳しい説明は、下に出る赤い枠（`_SecretServiceNotice`）が
/// 持つ。ここで同じ文を繰り返さない。
OfflineHomeCopy offlineHomeCopy({
  required bool allNeedLogin,
  required bool anyRetrying,
  required bool keyringUnavailable,
  required bool keyringLocked,
}) {
  if (allNeedLogin) {
    return (
      title: '未接続のアカウント',
      heading: '接続し直してください',
      // 待っても戻らないことを明示する。「自動で再試行」と書くと
      // 何もせず待たせることになる (#967)。
      body:
          'ログイン情報が見つかりません。端末の復元・データ削除・'
          '設定のインポートのあとに起こります。アカウントの一覧は'
          '残っているので、接続し直せば元に戻ります。',
    );
  }
  if (keyringUnavailable && keyringLocked) {
    return (
      title: 'キーリングがロックされています',
      heading: 'キーリングがロックされています',
      // ⚠ 自動の再試行はロックされたキーリングを読まない (#1386)。
      // 「自動で戻ります」と書くと、解除するまで待たせることになる。
      body: 'アカウントは保持しています。キーリングを解除すると、タイムラインへ戻ります。',
    );
  }
  if (keyringUnavailable) {
    return (
      title: 'ログイン情報を読み出せません',
      heading: anyRetrying ? '読み出し中…' : 'ログイン情報を読み出せません',
      body:
          'アカウントは保持したまま、ログイン情報の読み出しを自動で再試行'
          'します。読み出せれば、タイムラインへ戻ります。',
    );
  }
  return (
    title: '接続できません',
    heading: anyRetrying ? '接続中…' : '接続できません',
    // 原因を「サーバー側」と断定しない (#917)。この画面は機内モード等で
    // 端末がオフラインなときにも出る（到達不能の理由はここでは区別できない）。
    // ⚠ **「自動で再試行を続ける」は #938 で実装と一致した。**再び上限を
    // 入れるならここも戻すこと。
    body:
        '端末がオフラインか、ログイン中のサーバーが停止 / 再構築中の'
        '可能性があります。アカウントは保持したまま自動で再試行を'
        '続けるので、接続が回復すればタイムラインへ戻ります。',
  );
}

/// オフラインホームの、再試行で戻るアカウントの行に出す説明 (#1393)。
///
/// ⚠ キーリングが原因のときに「接続を待っています」と言わない（見出しと同じ
/// 理由）。ロック中は自動の再試行が読まないので、解除を待っていると言う。
String offlineAccountSubtitle({
  required bool retrying,
  required bool keyringUnavailable,
  required bool keyringLocked,
}) {
  if (keyringUnavailable && keyringLocked) return 'キーリングの解除を待っています';
  if (retrying) return '再試行中…';
  return keyringUnavailable ? 'ログイン情報の読み出しを待っています' : '接続を待っています';
}
