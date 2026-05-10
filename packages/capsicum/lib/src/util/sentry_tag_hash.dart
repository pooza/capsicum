import 'dart:convert';

/// Sentry tag 用の de-identification ハッシュ。暗号学的強度は不要のため
/// FNV-1a 64-bit で十分。同一入力が常に同一ハッシュに丸まるので相関は取れる
/// 一方、ハッシュから入力 (username 等) は復元不能。
///
/// 利用箇所:
/// - account_manager_provider: account_restore.user_hash
/// - main.dart: notification.routing.gave_up の payload.user_hash
String hashForSentryTag(String input) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  for (final byte in utf8.encode(input)) {
    hash = (hash ^ BigInt.from(byte)) * prime & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0').substring(0, 16);
}
