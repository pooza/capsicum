import 'dart:io' show Platform;

import 'package:url_launcher/url_launcher.dart';

export 'package:url_launcher/url_launcher.dart' show LaunchMode;

/// HTTP/HTTPS スキームを検証してから URL を開く。
///
/// 安全でないスキーム（javascript:, file: 等）のURLは無視する。
Future<bool> launchUrlSafely(
  Uri uri, {
  LaunchMode mode = LaunchMode.platformDefault,
}) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return Future.value(false);
  return launchUrl(uri, mode: mode);
}

/// 専用アプリで開くサービス (#755 / #1345)。
class PreferredAppService {
  const PreferredAppService(this.id, this.label, this.hostSuffixes);

  /// 設定に保存する名前。⚠ 変えると、外した設定が効かなくなる。
  final String id;
  final String label;

  /// ホストの**サフィックス**として照合する（`youtube.com` は `m.youtube.com` /
  /// `music.youtube.com` にも一致）。
  final Set<String> hostSuffixes;

  bool matches(String host) {
    final h = host.toLowerCase();
    return hostSuffixes.any((s) => h == s || h.endsWith('.$s'));
  }
}

/// 専用アプリで開くサービスの表。⚠ 拡張は原則ここへの追記だけで済む。足す候補の
/// 調べ方は #1345。設定画面（外せる）もこの表から作る。
const preferredAppServices = <PreferredAppService>[
  // 本文中で特に体験差が大きい
  PreferredAppService('youtube', 'YouTube', {'youtube.com', 'youtu.be'}),
  PreferredAppService('apple_music', 'Apple Music', {'music.apple.com'}),
  PreferredAppService('spotify', 'Spotify', {
    'open.spotify.com',
    'spotify.link',
  }),
  // ショッピング / Prime Video 等はアプリ側のルーティングに委ねる
  PreferredAppService('amazon', 'Amazon', {
    'amazon.co.jp',
    'amazon.com',
    'amzn.to',
    'amzn.asia',
  }),
  PreferredAppService('github', 'GitHub', {'github.com'}),
  PreferredAppService('x', 'X', {'x.com', 'twitter.com'}),
  // ⚠ iOS 向けの設定は全パスを除外している（`NOT *`）ので、iOS ではブラウザで開く。
  PreferredAppService('ameblo', 'アメーバブログ', {'ameblo.jp'}),
  PreferredAppService('wikipedia', 'Wikipedia', {'wikipedia.org'}),
];

/// [host] を専用アプリで開くか。[disabled] は利用者が外したサービスの id。
bool hasPreferredApp(String host, {Set<String> disabled = const {}}) =>
    preferredAppServices.any(
      (service) => !disabled.contains(service.id) && service.matches(host),
    );

/// 本文中の URL を、対応する専用アプリがあればそれで開く (#755)。
///
/// モバイル（iOS / Android）のみ専用アプリへの誘導を試みる。ホストが
/// [preferredAppServices] に一致する場合、まず
/// [LaunchMode.externalNonBrowserApplication] でネイティブアプリ起動を試み、
/// アプリ未インストール等で失敗したら [browserMode] でブラウザにフォールバック
/// する。それ以外（非対象ホスト・[disabledServices] で外したサービス・デスクトップ
/// ・非 http(s)）は [launchUrlSafely] にそのまま流す。
Future<bool> launchInPreferredApp(
  Uri uri, {
  LaunchMode browserMode = LaunchMode.platformDefault,
  Set<String> disabledServices = const {},
}) async {
  final isMobile = Platform.isIOS || Platform.isAndroid;
  if (isMobile &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      hasPreferredApp(uri.host, disabled: disabledServices)) {
    try {
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalNonBrowserApplication,
      );
      if (opened) return true;
    } catch (_) {
      // アプリ未インストール / このモード非対応。ブラウザにフォールバックする。
    }
  }
  return launchUrlSafely(uri, mode: browserMode);
}
