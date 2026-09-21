import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../service/secure_storage_gate.dart';

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
  // ⚠⚠ **Linux のキーリング (#1141)。**#644 が入れた分類は Apple の Keychain の
  // 形しか見ておらず、Linux の失敗は「ログインに失敗しました」に落ちていた。
  // 利用者はサーバーやパスワードを疑うが、原因は端末のキーリング。ホームの
  // 案内カードと同じ語（パスワード保管庫・キーリング / Secret Service）で言う。
  // Android で保管庫の暗号方式の移行が失敗し、回復（v1.66）でも書けなかった。
  // 以前は message に `secure` 等が無いので「ログインに失敗しました」に落ちていた。
  if (isAndroidSecureStorageMigrationFailure(error)) {
    return (
      kind: LoginFailureKind.secureStorage,
      message:
          'この端末のパスワード保管庫を更新できず、ログイン情報を保存できません'
          'でした。改善しない場合は、端末の設定でこのアプリのデータを消去してから'
          'ログインし直してください。',
    );
  }
  if (SecureStorageGate.isGateTimeout(error)) {
    return (kind: LoginFailureKind.secureStorage, message: _keyringMessage);
  }
  if (error is PlatformException) {
    switch (error.code) {
      // 解錠できなかった（解錠ダイアログのキャンセル・パスワード不一致を含む）。
      case 'KeyringLocked':
        return (
          kind: LoginFailureKind.secureStorage,
          message:
              'この端末のパスワード保管庫（キーリング / Secret Service）が'
              'ロックされているため、ログイン情報を保存できませんでした。'
              'キーリングを解錠してから、もう一度お試しください。',
        );
      // libsecret のその他の失敗 / プラグイン内部の失敗（JSON の破損等）。
      case 'Libsecret error':
      case 'StorageError':
        return (kind: LoginFailureKind.secureStorage, message: _keyringMessage);
    }
  }

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

/// Linux のキーリングに保存できなかったときの文言 (#1141)。
const _keyringMessage =
    'この端末のパスワード保管庫（キーリング / Secret Service）に'
    'ログイン情報を保存できませんでした。'
    'ほかのアプリでもパスワードの保存・読み出しに失敗している場合は、'
    '端末を再起動すると直ることがあります。';

/// セッション復元 (`restoreSessions`) の失敗を、アカウントをどう扱うかの
/// 観点で分類する (#792)。
///
/// [classifyLoginFailure] の `server` は 4xx/5xx を一括りにしているが、復元
/// では「サーバーが一時的に落ちている (5xx / ネットワーク不通)」と「認証が
/// 失効した (401/403)」を区別しないと、前者を誤ってログアウト扱いしてしまう。
enum RestoreOutcome {
  /// 一時的な到達不能 (ネットワーク不通 / サーバー 5xx)。secret は有効なので
  /// アカウントを消さずオフライン保持し、背景リトライで自動回復させる。
  retriable,

  /// 認証が失効した (401/403)。正規のログアウトなので再ログインを促す扱い。
  /// オフライン保持しない。
  authRevoked,

  /// 上記以外 (secure storage 失敗 / 4xx / 不明)。従来どおり skip + 観測。
  giveUp,
}

/// 復元例外 [error] を [RestoreOutcome] に分類する (#792)。
///
/// - ネットワーク不通 → `retriable`
/// - サーバー応答 5xx → `retriable` (一時障害・再構築中など)
/// - サーバー応答 401/403 → `authRevoked`
/// - それ以外 (secure storage / 4xx / 不明) → `giveUp`
RestoreOutcome classifyRestoreFailure(Object error) {
  final kind = classifyLoginFailure(error).kind;
  if (kind == LoginFailureKind.network) return RestoreOutcome.retriable;
  if (error is DioException && error.type == DioExceptionType.badResponse) {
    final code = error.response?.statusCode;
    if (code == 401 || code == 403) return RestoreOutcome.authRevoked;
    if (code != null && code >= 500) return RestoreOutcome.retriable;
  }
  return RestoreOutcome.giveUp;
}

/// [error] が「接続を張ろうとして即座に断られた」失敗かどうか (#989)。
///
/// **時間を使っていない失敗だけを true にするのが眼目。** 起動直後はプロセスの
/// ネットワークスタックが立ち上がりきっておらず、`connect(2)` がタイムアウトを
/// 待たずにエラーを返す窓がある。2026-08-18 の観測では **150 ms の間に 6
/// アカウント中 5 件がこれで落ち、その 213 ms 後には同じホストへ到達できていた**。
/// こういう失敗は、待つのではなく**すぐもう一度試せば通る**。
///
/// 逆に、次のものは false にする。もう一度すぐ試しても結果が変わらないか、
/// 既に時間を使っているため:
///
/// - `connectionTimeout` / `receiveTimeout` / `sendTimeout` … 既に待っている
/// - `badResponse` … サーバーには届いている（5xx は背景再試行の担当）
/// - `badCertificate` … 300 ms 後に証明書が変わることはない
/// - `cancel` … 呼び出し側が止めたもの
bool isImmediateConnectFailure(Object error) {
  if (error is DioException) {
    if (error.type == DioExceptionType.connectionError) return true;
    // dio が分類しきれず unknown へ落とすが、中身は接続レベルという経路。
    return error.type == DioExceptionType.unknown &&
        error.error is SocketException;
  }
  return error is SocketException;
}
