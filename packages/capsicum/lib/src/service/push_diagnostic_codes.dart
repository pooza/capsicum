/// Windows の push 診断コードのうち「正常系」の集合 (#1012)。
///
/// ⚠⚠ **ネイティブ `windows/runner/push_diagnostics.cpp` の `IsBenignCode` と
/// 完全一致させること。** 片方だけに足すと:
///
/// - **Dart にだけある** … ネイティブは異常系として扱うので、単一スロットの
///   診断レコードで正常系が異常系を上書きしなくなる（#997 で仕組んだ「異常を
///   優先して残す」が効かない）
/// - **ネイティブにだけある** … Dart が warning で上げるので、**正常運転の
///   コードが平常時の端末から毎回 warning で届く**（#997 の
///   `wns.announcement_deduped` がまさにこの形だった）
///
/// これまで一致を守っていたのは**両側のコメントだけ**で、検査が無かった。
/// C++ 側のテストは tag ビルドでしか回らない（`docs/tech-notes.md`「Windows
/// ネイティブを触ったときの検証手順」）ので、突き合わせは Dart 側の
/// `test/wns_benign_codes_parity_test.dart` が `.cpp` を読んで行う。
///
/// ⚠ **`*.shown` 系は「表示に成功したときだけ」記録される** (#957 / #978 /
/// #997)。表示失敗（`bgtask.show_failed` / `bgtask.announcement_show_failed` /
/// `wns.show_failed` / `wns.announcement_show_failed`）をここへ入れない。
library;

/// 正常運転として `info` で上げるコード。ここに無いものは `warning`。
const wnsBenignDiagnosticCodes = <String>{
  'bgtask.shown',
  'bgtask.announcement_shown',
  'bgtask.not_encrypted',
  'bgtask.not_raw',
  'wns.announcement_shown',
  // WebSocket 経路 (#569) が先に出したので抑止した = 通常運転 (#997)。
  'wns.announcement_deduped',
};
