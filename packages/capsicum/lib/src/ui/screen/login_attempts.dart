import 'package:flutter/foundation.dart';

/// 進行中のログイン試行を**プロセス全体で** 1 本に保つ登録簿 (#1112)。
///
/// ⚠ **なぜ State のフィールド（`_isLoggingIn`）だけでは足りないのか。**
/// `_isLoggingIn` は `_LoginScreenState` が持つので、**画面が作り直されると
/// false に戻る**。OAuth はブラウザへ出る往復があり、その間に Android が
/// アクティビティを再生成する経路が実際にある（#930 / #955 がその対処）。
/// 一方で **奪われる資源はプロセスに 1 つずつ**（ポート 7099 の HTTP サーバと
/// 認可待ちの keep-alive）なので、ガードも同じ寿命に合わせる必要がある。
///
/// ⚠⚠ **重なった試行を「弾く」のではなく「前を畳んで新しい方を通す」。**弾くと、
/// 画面が作り直されたあとユーザーがもう一度押しても**何も起きない**画面になり、
/// 前の試行の後片づけ（dispose）が終わるまで復帰できなくなる。実際に必要なのは
/// 「最後に押したものが生きている」ことなので、前の試行の資源を先に畳む。
class LoginAttempts {
  LoginAttempts._();

  static int _sequence = 0;

  /// いま走っている試行の通し番号。走っていなければ null。
  static int? _activeSequence;

  /// 走っている試行のプロセス資源を畳むための後片づけ。
  static Future<void> Function()? _activeTeardown;

  /// 何回目の試行か（1 始まり）。⚠ **プロセス通し**なので、画面を作り直しても
  /// 連番が続く＝「同じ操作で 2 回走った」が番号で見える。
  static int nextSequence() => ++_sequence;

  static int? get activeSequence => _activeSequence;

  /// [sequence] の試行を「走っている」ものとして登録する。既に走っているものが
  /// あればその後片づけを**待ってから**差し替える（ポートの解放待ちを含む）。
  static Future<int?> takeOver(
    int sequence,
    Future<void> Function() teardown,
  ) async {
    final previous = _activeSequence;
    final previousTeardown = _activeTeardown;
    _activeSequence = sequence;
    _activeTeardown = teardown;
    if (previousTeardown != null) await previousTeardown();
    return previous;
  }

  /// [sequence] の試行を終わりにする。⚠ **自分が最新のときだけ降りる** — 後から
  /// 始まった試行を、先に始まった試行の `finally` が消さないため（`a4d86f64` の
  /// keep-alive 世代ガードと同じ理由）。
  static void release(int sequence) {
    if (_activeSequence != sequence) return;
    _activeSequence = null;
    _activeTeardown = null;
  }

  /// テスト用。プロセス状態を初期化する。
  @visibleForTesting
  static void resetForTest() {
    _sequence = 0;
    _activeSequence = null;
    _activeTeardown = null;
  }
}
