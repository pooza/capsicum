/// 投稿アクションの呼称を 1 箇所で決める (#1035-E1)。
///
/// ⚠⚠ **同じ三項式が 4 箇所 + ネイティブ 1 箇所へ写されていた。**
/// `server_config_provider`（現在アカウント用の provider）/
/// `account_manager_provider`（プッシュ通知のラベル解決）/
/// `cross_account_boost`（別アカウントの文脈）/ `main.dart`（プッシュ payload の
/// アカウント文字列から解決）に、`mulukhiya?.reblogLabel ?? (adapter is
/// ReactionSupport ? 'リノート' : 'ブースト')` が同じ形で並んでいた。
///
/// ⚠ **#1027-C2 は「用語の正本は `reblogLabelProvider`」を掲げた回**なのに、
/// その回で畳んだのは `userAcct` と `ReactionPhase` で、**主題である用語の複写は
/// 畳まれていなかった**。provider だけでは足りないのは、**別アカウント / プッシュ
/// payload の文脈では provider を使えない**（現在アカウントではない）ため。
/// [Account] を受ける関数にして初めて 4 箇所とも同じ実装を通せる。
///
/// ⚠ **Windows native の既定（`notification_type_label.cpp`）とは手動同期。**
/// Dart から共有できないので、文言を変えるときは向こうも直す。
library;

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';

import '../model/account.dart';

/// ブースト / リノートの呼称。
///
/// モロヘイヤの `reblog_label`（例: キュアスタ！の「リキュア！」）があれば
/// それを優先し、無ければ backend の種別で分岐する。
///
/// ⚠ **判定は `adapter is ReactionSupport`**（docs/CLAUDE.md の機能マッピング）。
/// Misskey 判定をここ以外の形で書かないこと。
String reblogLabelFrom(MulukhiyaService? mulukhiya, Object? adapter) =>
    mulukhiya?.reblogLabel ?? (adapter is ReactionSupport ? 'リノート' : 'ブースト');

/// 投稿の呼称（例: キュアスタ！の「キュア！」）。
String postLabelFrom(MulukhiyaService? mulukhiya) =>
    mulukhiya?.postLabel ?? '投稿';

/// [account] の文脈での [reblogLabelFrom]。
///
/// [account] が null（プッシュ payload のアカウントが手元に無い等）のときは
/// backend が分からないので既定の「ブースト」になる。従来の 4 箇所も同じ
/// 振る舞いだった。
String reblogLabelFor(Account? account) =>
    reblogLabelFrom(account?.mulukhiya, account?.adapter);

/// [account] の文脈での [postLabelFrom]。
String postLabelFor(Account? account) => postLabelFrom(account?.mulukhiya);
