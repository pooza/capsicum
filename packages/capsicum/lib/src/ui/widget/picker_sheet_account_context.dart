import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart';

import '../../model/account.dart';

/// ピッカーシート（リアクション #907 / スタンプ #883）を開くときに、シートの
/// `builder` / `onSelected` が遅延実行される時点で `currentAccountProvider` が
/// 入れ替わっていても安全なよう、**開く瞬間に確定した非 null 値だけ**を退避する束。
///
/// closure 内で `!` / `as` を再評価すると、実行時にアカウントが消えていた場合に
/// Null check operator で落ちる（#739 / Sentry CAPSICUM-32）。
///
/// 2 つのピッカーで同じ退避処理と #739 コメントが約 6 行ずつ二重化しており、
/// 将来 #739 型の対策を足すとき片方だけ直す事故が起きうるので 1 箇所へ寄せた
/// (#960)。
class PickerSheetAccountContext {
  const PickerSheetAccountContext({
    required this.backend,
    required this.host,
    required this.mulukhiya,
    required this.accessToken,
    required this.screenHeight,
  });

  final BackendAdapter backend;
  final String host;
  final MulukhiyaService? mulukhiya;
  final String accessToken;

  /// キーボードを含まない画面高（比率の基準）。シート表示後のキーボード開閉で
  /// 不変にするため、**開く前の親 [context]** から取る。
  final double screenHeight;

  /// [account]（呼び出し側で非 null かつ目的の mixin を満たすと確認済み）と親
  /// [context] から退避値を作る。
  static PickerSheetAccountContext capture({
    required BuildContext context,
    required Account account,
  }) => PickerSheetAccountContext(
    backend: account.adapter as BackendAdapter,
    host: account.key.host,
    mulukhiya: account.mulukhiya,
    accessToken: account.userSecret.accessToken,
    screenHeight: MediaQuery.of(context).size.height,
  );
}
