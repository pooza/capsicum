/// 修正前の版を `git show` で読むガード群が共有する口 (#1301)。
///
/// ## なぜ共有するのか
///
/// ⚠⚠ **`Process.runSync` は、`stdoutEncoding` を渡さないと [systemEncoding] で
/// 読む。**日本語版の Windows ではこれが CP932 なので、**UTF-8 のソースが化ける**。
/// 化けたまま `maskComments` を通すと引用符やコメントの区切りを取り違え、
/// ソースの大半が空白に潰れる。2026-10-18 に Windows 機（x64）で、歯の確認
/// （修正前の版を読んで「当たる」ことを見るテスト）が **6 件落ちていた**のがこれで、
/// CI（Linux）と macOS では緑だった（`systemEncoding` が UTF-8 のため）。
///
/// ⚠ **逆向きの穴のほうが危ない。**「修正前の版には無かった」を見る歯の確認は、
/// 化けて潰れたソースでも「無い」ので**緑のまま空振りする**。
///
/// そのため `git` の呼び出しはここへ寄せ、**常に UTF-8 で読む**。
///
/// ⚠ **test 配下でこのヘルパーを迂回していないこと**は
/// `git_show_guard_test.dart` が見ている。
library;

import 'dart:convert';
import 'dart:io';

/// `git show <spec>` の結果。[spec] は `<rev>:<リポジトリ root からのパス>`
/// （`'b5d6147f:packages/capsicum/lib/src/router.dart'`）。
///
/// 呼び出し側のテストのカレントはパッケージ（`packages/capsicum`）なので、
/// リポジトリ root（`../..`）で実行する。
///
/// - stdout は**厳密な** UTF-8 で読む。ソースはすべて UTF-8 なので、
///   読めなければ化けたまま検査させずに例外で落とす
/// - stderr は壊れた並びを許す（git のメッセージの言語・符号化は端末の設定
///   しだいで、失敗の理由を読むためだけに使うので）
///
/// 終了コードの扱い（落とす / スキップする）は呼び出し側が決める。
ProcessResult gitShow(String spec) => Process.runSync(
  'git',
  ['show', spec],
  workingDirectory: '../..',
  stdoutEncoding: utf8,
  stderrEncoding: const Utf8Codec(allowMalformed: true),
);
