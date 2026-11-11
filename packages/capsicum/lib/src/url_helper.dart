import 'dart:io' show Platform;

import 'package:url_launcher/url_launcher.dart';

import 'service/jump_plus_resolver.dart';

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
  const PreferredAppService(
    this.id,
    this.label,
    this.hostSuffixes, {
    this.appUrlFor,
  });

  /// 設定に保存する名前。⚠ 変えると、外した設定が効かなくなる。
  final String id;
  final String label;

  /// ホストの**サフィックス**として照合する（`youtube.com` は `m.youtube.com` /
  /// `music.youtube.com` にも一致）。
  final Set<String> hostSuffixes;

  /// アプリへ渡す URL を求める (#1352)。null を返したらアプリを試さずブラウザで
  /// 開く。省略したサービスは、押した URL をそのままアプリへ渡す。
  ///
  /// ⚠ Web の URL がアプリに渡らない（アプリが受け持つパスが違う）サービス用。
  final Future<Uri?> Function(Uri uri)? appUrlFor;

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
  // ⚠ 「勇者アバンと獄炎の魔王」だけ（#1352・決め打ちの理由は jumpPlusAppUrlFor）。
  // ほかの作品はアプリを試さずブラウザで開く。
  PreferredAppService('jumpplus_aban', '少年ジャンプ＋（勇者アバン）', {
    'shonenjumpplus.com',
  }, appUrlFor: jumpPlusAppUrlFor),
];

/// [host] に当たるサービス。[disabled] は利用者が外したサービスの id。
PreferredAppService? preferredAppServiceFor(
  String host, {
  Set<String> disabled = const {},
}) {
  for (final service in preferredAppServices) {
    if (!disabled.contains(service.id) && service.matches(host)) {
      return service;
    }
  }
  return null;
}

/// [host] を専用アプリで開くか。[disabled] は利用者が外したサービスの id。
bool hasPreferredApp(String host, {Set<String> disabled = const {}}) =>
    preferredAppServiceFor(host, disabled: disabled) != null;

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
  final service = isMobile && (uri.scheme == 'http' || uri.scheme == 'https')
      ? preferredAppServiceFor(uri.host, disabled: disabledServices)
      : null;
  if (service == null) return launchUrlSafely(uri, mode: browserMode);
  if (service.appUrlFor == null) {
    return _launchViaPreferredApp(service, uri, browserMode);
  }
  // ⚠⚠ 開く URL を求めに行くサービス（ジャンプ＋・#1352）は、**調べて開く
  // 操作ごと**同じ URL で 1 回にまとめる（v2.11 のリリース前レビューの Codex P2）。
  // 求めている間は画面に何も出ないので押し直されやすい。求める処理だけを
  // まとめても、待っていた呼び出しがそれぞれ開くので、アプリ（かブラウザ）が
  // 2 回開く（最初の修正はこの形で、狙いを果たしていなかった）。
  final key = uri.toString();
  return _pendingPreferredLaunches[key] ??= () async {
    try {
      return await _launchViaPreferredApp(service, uri, browserMode);
    } finally {
      _pendingPreferredLaunches.remove(key);
    }
  }();
}

/// 開いている途中の、専用アプリで開く操作（URL ごと）。
final _pendingPreferredLaunches = <String, Future<bool>>{};

Future<bool> _launchViaPreferredApp(
  PreferredAppService service,
  Uri uri,
  LaunchMode browserMode,
) async {
  final appUri = await preferredAppUriFor(service, uri);
  if (appUri != null) {
    try {
      final opened = await launchUrl(
        appUri,
        mode: LaunchMode.externalNonBrowserApplication,
      );
      if (opened) return true;
    } catch (_) {
      // アプリ未インストール / このモード非対応。ブラウザにフォールバックする。
    }
  }
  return launchUrlSafely(uri, mode: browserMode);
}

/// [service] のアプリへ渡す URL (#1352)。null ならアプリを試さない。
///
/// ⚠ 求める処理の失敗は null（ブラウザで開く）。リンクが開かなくなるより、
/// ブラウザで開くほうがよい。
Future<Uri?> preferredAppUriFor(PreferredAppService service, Uri uri) async {
  final appUrlFor = service.appUrlFor;
  if (appUrlFor == null) return uri;
  try {
    return await appUrlFor(uri);
  } catch (_) {
    return null;
  }
}
