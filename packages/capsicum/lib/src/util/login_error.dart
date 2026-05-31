import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

/// ログイン処理中に発生した例外の分類 (#644)。
///
/// 旧実装はキャンセル以外のあらゆる例外を「通信に失敗しました」と表示して
/// おり、Keychain 保存失敗 (#643 の errSecInteractionNotAllowed -25308) の
/// ようなネットワークと無関係な失敗まで通信エラーと誤診させていた。
enum LoginFailureKind {
  /// secure storage / Keychain への保存・読み出し失敗。
  secureStorage,

  /// ネットワーク到達性・接続レベルの失敗。
  network,

  /// サーバーがステータスコード付きでエラー応答を返した (HTTP 4xx/5xx 等)。
  server,

  /// 上記いずれにも分類できない失敗。
  unknown,
}

/// 分類結果。[message] はそのままユーザーに表示できる日本語文言。
///
/// 名称は `capsicum_core` の `LoginFailure` (LoginResult のサブタイプ) との
/// 衝突を避けて `LoginFailureInfo` とする。
typedef LoginFailureInfo = ({LoginFailureKind kind, String message});

/// ログイン例外 [error] を [LoginFailureKind] に分類し、表示文言を返す。
///
/// 認証ロジックには一切影響しない純粋な分類関数 (#644)。Sentry には
/// `login.failure_kind` タグとして [LoginFailureKind.name] を添えると
/// 後追いが容易になる。
LoginFailureInfo classifyLoginFailure(Object error) {
  // flutter_secure_storage は Apple 系で PlatformException を投げる。
  // errSecInteractionNotAllowed (-25308) 等の Keychain エラーはネットワーク
  // と無関係なので専用文言に分ける (#643)。
  if (error is PlatformException) {
    final detail = '${error.code} ${error.message}'.toLowerCase();
    if (detail.contains('errsec') ||
        detail.contains('-25308') ||
        detail.contains('keychain') ||
        detail.contains('secure') ||
        detail.contains('secitem')) {
      return (
        kind: LoginFailureKind.secureStorage,
        message: 'ログイン情報の保存に失敗しました',
      );
    }
  }

  if (error is DioException) {
    // badResponse はサーバーがステータスコード付きで応答している = 到達は
    // できているので「通信失敗」とは区別する。それ以外 (timeout /
    // connectionError / badCertificate 等) は接続レベルの失敗。
    if (error.type == DioExceptionType.badResponse) {
      return (kind: LoginFailureKind.server, message: 'サーバーがエラーを返しました');
    }
    return (kind: LoginFailureKind.network, message: '通信に失敗しました');
  }

  // dart:io の低レベルなネットワーク / TLS 例外。
  // TlsException は HandshakeException / CertificateException の基底。
  if (error is SocketException ||
      error is HttpException ||
      error is TlsException) {
    return (kind: LoginFailureKind.network, message: '通信に失敗しました');
  }

  return (kind: LoginFailureKind.unknown, message: 'ログインに失敗しました');
}
