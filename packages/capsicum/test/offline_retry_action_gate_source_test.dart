import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #1014: 「押しても何も起きないボタン」を出さないことの検査。
///
/// `AccountManagerNotifier.retryOfflineRestores` の対象は #967 / #1001 以降
/// `recoverableByRetry` で絞られており、**secret 消失（未接続）のアカウントは
/// 必ず除外される**。したがって全件が未接続の状態では再試行が空振りする。
/// にもかかわらずオフラインホームは「今すぐ再試行」を出したままで、**画面の
/// 説明文が「待っても戻らない」と言っているのに押せるボタンがある**という
/// 矛盾になっていた（Codex P2 / リリース PR #1003）。
///
/// ⚠ **widget test にできない。**受け皿の `_OfflineHomeScaffold` は private で、
/// `HomeScreen.build` がオンラインアカウント 0 件の状態を作らないと到達しない。
/// 分岐そのものは 1 行の条件なので、`alt_edit_gate_source_test.dart` と同じく
/// **出し分けの有無をソースで固定する**（#999 で確立した形）。
///
/// 対になる挙動（除外そのもの）は `offline_account_reason_test.dart` と
/// `account_manager_add_disconnected_test.dart` が持つ。
void main() {
  String homeScreenSource() =>
      File('lib/src/ui/screen/home_screen.dart').readAsStringSync();

  // ⚠ **インデントを直書きしない。**見たいのは「ボタンが分岐の直下にある」こと
  // だけで、桁数はレイアウト側の都合で動く。実際 #1037 で body を
  // `BottomSafeArea` で包んだ際、中身は 1 文字も変えていないのに
  // `dart format` の再整形（2 桁ぶんの字下げ）だけでこの検査が落ちた。
  // 意味のない失敗は「検査を直せば通る」学習を生むので、空白は正規表現で吸う。
  // `...[` は spread の分岐にだけ付くので**丸ごと任意**にする。オフラインホーム
  // 側は `if (...) ...[ Widget` 形式、ドロワー側は `if (...) Widget` 形式で、
  // 同じ「分岐の直下か」を見たい。
  Matcher gatedBy(String condition, String widget) => matches(
    RegExp(
      '${RegExp.escape(condition)}\\s*(?:\\.\\.\\.\\[)?\\s*'
      '${RegExp.escape(widget)}',
    ),
  );

  test('全件が未接続なら「今すぐ再試行」を出さない', () {
    expect(
      homeScreenSource(),
      gatedBy('if (!allNeedLogin)', 'FilledButton.icon('),
      reason:
          'retryOfflineRestores は secretMissing を除外するので、'
          'この状態のボタンは押しても黙って何も起きない',
    );
  });

  test('再試行の導線はオフラインホームに 1 つだけ', () {
    final occurrences = '今すぐ再試行'.allMatches(homeScreenSource()).length;

    expect(
      occurrences,
      1,
      reason:
          '写しが増えると、片方だけ出し分けを足して片方が空振りのまま残る'
          '（#996 が「母数の取りこぼし」で繰り返し踏んだ形）',
    );
  });

  // ドロワーの切替リストは**アカウント単位**で同じ出し分けをしている (#967)。
  // オフラインホームだけ直してこちらが崩れると、同じ穴が別画面で開く。
  test('ドロワー側もアカウント単位で再試行を出し分ける', () {
    final source = homeScreenSource();

    expect(
      source,
      gatedBy('if (!needsLogin)', 'IconButton('),
      reason: '未接続のアカウントに「再試行」アイコンを出さない',
    );
    expect(
      source,
      gatedBy('if (needsLogin)', 'IconButton('),
      reason: '代わりに「接続し直す」を出す',
    );
  });
}
