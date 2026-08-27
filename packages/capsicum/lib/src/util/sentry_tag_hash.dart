import 'dart:convert';

import '../model/account_key.dart';

/// Sentry tag 用の de-identification ハッシュ。暗号学的強度は不要のため
/// FNV-1a 64-bit で十分。同一入力が常に同一ハッシュに丸まるので相関は取れる。
///
/// ⚠ **「復元不能」ではない (#1027-C)。**無塩の FNV-1a なので、**候補の
/// アカウント名が分かっていれば総当たりで照合できる**（1 件あたり数十ナノ秒）。
/// ここが担保しているのは「**そのままでは読めない**」ことだけで、
/// 「誰か分からない」ではない。以前の doc は「復元不能」と書いており、
/// 強度を過大に見せていた。
///
/// この水準で足りるのは、守りたいのが「Sentry の画面を開いた人が**偶然**
/// ユーザー名を目にする」ことだからで、当てにいく相手に対する防御ではない。
/// それが要る場面では、そもそも載せない判断をすること。
String hashForSentryTag(String input) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  for (final byte in utf8.encode(input)) {
    hash = (hash ^ BigInt.from(byte)) * prime & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0').substring(0, 16);
}

/// breadcrumb / ログに載せてよいアカウントの識別子 (#1027-B)。
///
/// ⚠⚠ **`accountKey.toStorageKey()` や `username@host` を素で載せないこと。**
/// release ビルドでは sentry_flutter が `debugPrint` を丸ごと breadcrumb 化し、
/// breadcrumb の `message` は `main.dart` の `_scrubBreadcrumb`（`data` しか
/// 見ない）を通らない。**書いた文字列がそのまま Sentry に出る。**
///
/// **host はそのまま出す。**プリセットサーバーかどうかで対応の優先度を切る
/// 運用があり、素性が分からないとトリアージできない。潰すのは username だけ。
///
/// ⚠ 得られるのは [hashForSentryTag] の水準（「そのままでは読めない」）で
/// あって匿名化ではない。そちらの doc を参照。
String sentrySafeAccount(AccountKey key) =>
    '${hashForSentryTag(key.username)}@${key.host}';

/// storage key（`mastodon://user@host`）から [sentrySafeAccount] を作る。
///
/// ⚠ **parse 失敗を握り潰して素のキーへ落とさないこと。**legacy / 破損キーは
/// 「読めなかった」と分かる形にして、**元の文字列は出さない**（そこが機微な
/// のに、壊れているときだけ素通しになるのでは意味が無い）。
String sentrySafeAccountKey(String storageKey) {
  try {
    return sentrySafeAccount(AccountKey.fromStorageKey(storageKey));
  } catch (_) {
    return '(unparsable-account-key)';
  }
}
