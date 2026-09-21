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
///
/// ## ⚠ 「最新か」は資源を掴む直前にも聞く (#1144)
///
/// [takeOver] が畳めるのは**その瞬間に存在する資源**だけ。入口から実際に
/// ポートを bind するまでには adapter の生成・secure storage の読み出し・
/// `POST /api/v1/apps` が挟まる（数百 ms〜数秒）。**#1112 が観測した「同じ操作で
/// 2 本」はまさにこの窓**で、両方が 7099 へ行って「他プロセスに占有されています」
/// という誤った案内になる。だから掴む直前に [isCurrent] で確かめ、追い越されて
/// いたら掴まずに降りる。
class LoginAttempts {
  LoginAttempts._();

  static int _sequence = 0;

  static _Attempt? _active;

  /// 何回目の試行か（1 始まり）。⚠ **プロセス通し**なので、画面を作り直しても
  /// 連番が続く＝「同じ操作で 2 回走った」が番号で見える。
  static int nextSequence() => ++_sequence;

  static int? get activeSequence => _active?.sequence;

  /// [sequence] がまだ最新の試行か。⚠ **資源を掴む直前に聞く**（上の doc）。
  static bool isCurrent(int sequence) => _active?.sequence == sequence;

  /// [sequence] の試行が通ったステップを覚える。重なったときに「前の試行が
  /// どこまで進んでいたか」として送る (#1144)。最新の試行のぶんだけ覚える。
  static void markStep(int sequence, String step) {
    final active = _active;
    if (active != null && active.sequence == sequence) active.lastStep = step;
  }

  /// [sequence] の試行を「走っている」ものとして登録する。既に走っているものが
  /// あればその後片づけを**待ってから**戻る（ポートの解放待ちを含む）。
  ///
  /// [owner] は試行を始めた State。重なったときに「同じ画面での押し直しか、
  /// 作り直された別の画面か」を見分けるのに使う（#1112 が立てた問い）。
  ///
  /// ⚠⚠ **戻ってきたら [LoginTakeOver.superseded] を見ること (#1144)。**後片づけを
  /// 待っている間に 3 本目が来ると、3 本目が最新になる。以前は 2 本目もそのまま
  /// 続行し、2 本目と 3 本目が両方 7099 へ行った（Codex P2 / PR #1118）。
  static Future<LoginTakeOver> takeOver(
    int sequence, {
    required Object owner,
    required Future<void> Function() teardown,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final previous = _active;
    _active = _Attempt(
      sequence: sequence,
      owner: identityHashCode(owner),
      startedAt: at,
      teardown: teardown,
    );
    LoginOverlap? overlap;
    if (previous != null) {
      overlap = LoginOverlap(
        previousSequence: previous.sequence,
        sameOwner: previous.owner == identityHashCode(owner),
        previousAge: at.difference(previous.startedAt),
        previousStep: previous.lastStep,
      );
      try {
        await previous.teardown();
      } catch (_) {
        // ⚠ 後片づけの失敗で新しい試行を止めない。資源は各試行の finally も
        // 閉じにいくので、ここで握っても取り残しにはならない。
      }
    }
    return LoginTakeOver(overlap: overlap, superseded: !isCurrent(sequence));
  }

  /// [sequence] の試行を終わりにする。⚠ **自分が最新のときだけ降りる** — 後から
  /// 始まった試行を、先に始まった試行の `finally` が消さないため（`a4d86f64` の
  /// keep-alive 世代ガードと同じ理由）。
  static void release(int sequence) {
    if (isCurrent(sequence)) _active = null;
  }

  /// テスト用。プロセス状態を初期化する。
  @visibleForTesting
  static void resetForTest() {
    _sequence = 0;
    _active = null;
  }
}

/// [LoginAttempts.takeOver] の結果。
class LoginTakeOver {
  const LoginTakeOver({required this.overlap, required this.superseded});

  /// 前の試行が走っていた。走っていなければ null。
  final LoginOverlap? overlap;

  /// 後片づけを待っている間に、さらに新しい試行に追い越された。⚠ true なら
  /// 何も掴まずに降りること。
  final bool superseded;
}

/// 重なった前の試行について分かっていること (#1144)。
///
/// ⚠ 以前は `was_logging_in` / `mounted` を送っていたが、どちらも**その 40 行上で
/// 立てた値を読むので常に true**＝定数で、#1112 の問いに答えられなかった。
class LoginOverlap {
  const LoginOverlap({
    required this.previousSequence,
    required this.sameOwner,
    required this.previousAge,
    required this.previousStep,
  });

  final int previousSequence;

  /// 同じ State からの押し直しか（false なら画面が作り直されている）。
  final bool sameOwner;

  /// 前の試行が始まってからの経過。
  final Duration previousAge;

  /// 前の試行が最後に通ったステップ。
  final String? previousStep;

  /// ⚠ **すぐ重なったか。**#1112 の「1 回の操作で 2 本」はこちら。ブラウザから
  /// 戻って押し直した**良性の入り直し**は前の試行が数秒以上前に始まっており、
  /// 認可待ち（最大 5 分）のまま登録簿に残っているので必ず重なる。両者を同じ
  /// warning で上げると、母数が入り直しで埋まって本命が見えなくなる。
  bool get isRapid => previousAge < rapidThreshold;

  static const rapidThreshold = Duration(seconds: 2);
}

class _Attempt {
  _Attempt({
    required this.sequence,
    required this.owner,
    required this.startedAt,
    required this.teardown,
  });

  final int sequence;
  final int owner;
  final DateTime startedAt;
  final Future<void> Function() teardown;
  String? lastStep;
}
