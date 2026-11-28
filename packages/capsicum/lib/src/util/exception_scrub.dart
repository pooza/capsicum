import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// DioException や OAuth 例外のメタ情報のみを抜き出した安全な例外に詰め替える。
///
/// Dio はバージョンによって `requestOptions.uri` を `message` や `toString()` に
/// 埋め込むケースがあり、URL には relay の `push_token` や Mastodon
/// `client_secret` クエリが含まれることがある。Sentry / debugPrint / ログ
/// ファイルに流す前に必ずこのユーティリティを通す。
///
/// `service.push_registration` の relay 経路、`ui.login_screen` の OAuth
/// fallback 経路、`provider.chat_provider` の WebSocket 接続例外 (#552) で
/// 共通利用 (#499)。
///
/// DioException 以外でも、`WebSocketChannelException` / `SocketException`
/// 等が `toString()` に `wss://host/streaming?i=<accessToken>` のような
/// 機密クエリ付き URL を含めることがあるため、文字列表現から既知の機密
/// クエリパラメータ (`i` / `token` / `access_token` / `push_token` /
/// `client_secret`) の値をマスクして詰め替える。
Object scrubException(Object e) {
  if (e is DioException) {
    // クエリだけでなくパスセグメントにも機密が載ることがある。MiAuth の
    // `/api/miauth/<session>/check` は認可待ちのセッション UUID をパスに持つ
    // ため、ポーリング失敗 (#276) の DioException でそのまま載ると Sentry に
    // 有効な session が出る。既知の機密セグメントはマスクする (#790 レビュー)。
    final path = _scrubAuthority(
      e.requestOptions.path.split('?').first,
    ).replaceAllMapped(_sensitivePathSegment, (m) => '${m[1]}***${m[2]}');
    return StateError(
      'DioException ${e.type.name} '
      'status=${e.response?.statusCode ?? '-'} '
      'path=$path',
    );
  }
  if (e is IAPError) {
    // IAPError.details はプラットフォーム例外の内部情報（StoreKit /
    // Play Billing の PlatformException details 等）を含みうるため、
    // 識別子の source / code のみに詰め替える (#428)。
    return StateError('IAPError source=${e.source} code=${e.code}');
  }
  if (e is FormatException) {
    // FormatException.toString() は source（パース対象の生データ断片）を
    // 含む。streaming のフレーム parse 失敗時に投稿本文の断片が混入する
    // ため、message のみ残して source / offset は落とす (#586)。
    return StateError('FormatException: ${e.message}');
  }
  if (e is FileSystemException) {
    // toString() は対象のパスを含む。利用者が選んだ画像のパス（ホームの
    // ユーザー名が入る）や、アカウントごとの保存先が載るので落とす (#1353 の
    // リリース前レビュー)。種類と OS のエラー番号だけ残す。
    return StateError(
      '${e.runtimeType}: ${e.message} '
      'errno=${e.osError?.errorCode ?? '-'}',
    );
  }
  final text = e.toString();
  if (_sensitiveQueryParam.hasMatch(text)) {
    return StateError(
      '${e.runtimeType}: '
      '${text.replaceAllMapped(_sensitiveQueryParam, (m) => '${m[1]}***')}',
    );
  }
  return e;
}

/// キャッチした例外をログへ出す共通経路 (#926)。
///
/// release ビルドでは sentry_flutter が `debugPrint` を丸ごと breadcrumb 化する
/// ため、`debugPrint('...: $e')` の形で生の例外を埋めると、DioException の URL
/// （relay の `push_token` / Mastodon `client_secret`）や WebSocket の accessToken
/// などがそのまま Sentry に載る。この経路を通すことで [scrubException] のマスクを
/// 必ず経由させ、「生の例外を直接埋める」形をリポジトリから無くす。
///
/// [context] は「どこで何に失敗したか」の識別子（従来 `debugPrint` に書いていた
/// 前置き）。[stackTrace] は任意で、渡すと改行して続ける（従来 `$e\n$st` としていた
/// 箇所の代替）。スタックはコード位置であり機微データを含まない前提で素通しする。
void debugLogException(String context, Object error, [StackTrace? stackTrace]) {
  final scrubbed = scrubException(error);
  debugPrint(
    stackTrace == null
        ? '$context: $scrubbed'
        : '$context: $scrubbed\n$stackTrace',
  );
}

final _sensitiveQueryParam = RegExp(
  r'''([?&](?:i|token|access_token|push_token|client_secret)=)[^&\s'"]+''',
  caseSensitive: false,
);

/// 絶対 URL の authority から、利用者が打ったものを落とす (#1424)。
///
/// サーバーの接続の確認（probe）は、サーバーの欄に打たれた文字列をそのまま
/// `https://<入力>/...` に組むので、メールアドレスを打たれると path に残る
/// （CAPSICUM-7C）。
///
/// - `@`（半角・全角）より前は userinfo として落とす
/// - 残りに ASCII の `.` が無ければ、ホスト名として成り立たないので
///   `<invalid>` にする（`serverProbeHostTag` と同じ線・IDN は `.` を持つので残る）
///
/// 相対パス（relay の `/register/<id>` など）には当たらない。
///
/// ⚠ **scheme が重なった URL も見る**（リリース前レビュー・v2.15）。サーバーの欄に
/// `https://foo@mail.example` と打たれると `https://https://foo@mail.example/...`
/// になり、最初の authority は `https:` だけ。その後ろの `//` で始まる分も
/// authority として同じく落とす。
String _scrubAuthority(String path) {
  final m = _absoluteUrlAuthority.firstMatch(path);
  if (m == null) return path;
  final out = StringBuffer(m[1]!)..write(_cleanAuthority(m[2]!));
  var rest = path.substring(m.end);
  while (rest.startsWith('//')) {
    final end = rest.indexOf('/', 2);
    out
      ..write('//')
      ..write(
        _cleanAuthority(end < 0 ? rest.substring(2) : rest.substring(2, end)),
      );
    rest = end < 0 ? '' : rest.substring(end);
  }
  out.write(rest);
  return out.toString();
}

String _cleanAuthority(String authority) {
  final at = authority.lastIndexOf(_userinfoSeparator);
  final host = at >= 0 ? authority.substring(at + 1) : authority;
  return host.contains('.') ? host : '<invalid>';
}

final _absoluteUrlAuthority = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/]*)');
final _userinfoSeparator = RegExp('[@＠]');

/// パスに載る機密セグメントのマスク。現状は MiAuth の
/// `/api/miauth/<session>/check` の session UUID を対象にする (#790)。
final _sensitivePathSegment = RegExp(r'(/api/miauth/)[^/]+(/check)');
