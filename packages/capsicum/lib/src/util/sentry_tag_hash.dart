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
/// `main.dart` の `_scrubBreadcrumb` が breadcrumb の `message` に当てるのは
/// **relay の push token マスクだけ**（範囲の正本はそちらの doc・#1035-D2）で、
/// **アカウント識別子は素通しする**。書いた文字列がそのまま Sentry に出る。
///
/// **host はそのまま出す。**プリセットサーバーかどうかで対応の優先度を切る
/// 運用があり、素性が分からないとトリアージできない。潰すのは username だけ。
///
/// ⚠ 得られるのは [hashForSentryTag] の水準（「そのままでは読めない」）で
/// あって匿名化ではない。そちらの doc を参照。
String sentrySafeAccount(AccountKey key) =>
    '${hashForSentryTag(key.username)}@${key.host}';

/// アカウントを指す文字列から [sentrySafeAccount] を作る。
///
/// 受けるのは 2 つの形。**どちらで渡しても同じ `hash@host` になる**:
///
/// - storage key: `mastodon://user@host`（`AccountKey.toStorageKey()` の形）
/// - **relay payload の `account`: `user@host`**（scheme 無し）
///
/// ⚠⚠ **scheme 無しを受けるのは、渡し間違いが黙って host まで消すため**
/// (#1035-B1)。`Uri.parse('alice@example.test')` は scheme も userInfo も空に
/// なるので `BackendType` の探索が `StateError` になり、**丸ごと
/// `(unparsable-account-key)` に落ちていた**。プッシュ不達の切り分けでいちばん
/// 読む breadcrumb がそれで、[sentrySafeAccount] が「host はそのまま出す」と
/// 決めている当の情報が、**この経路でだけ**消えていた。
///
/// **「呼び分けの規約」ではなく「どちらでも正しい関数」にしてある。**呼び分けを
/// 規約で守ると、次に payload 側から呼んだ人がまた同じ穴を踏む。
///
/// ⚠ **parse 失敗を握り潰して素のキーへ落とさないこと。**legacy / 破損キーは
/// 「読めなかった」と分かる形にして、**元の文字列は出さない**（そこが機微な
/// のに、壊れているときだけ素通しになるのでは意味が無い）。
String sentrySafeAccountKey(String storageKey) {
  try {
    return sentrySafeAccount(AccountKey.fromStorageKey(storageKey));
  } catch (_) {
    // scheme 無しの `user@host`。username だけ潰して host は残す。
    final at = storageKey.lastIndexOf('@');
    if (at > 0 && at < storageKey.length - 1 && !storageKey.contains('://')) {
      final username = storageKey.substring(0, at);
      final host = storageKey.substring(at + 1);
      return '${hashForSentryTag(username)}@$host';
    }
    return '(unparsable-account-key)';
  }
}
