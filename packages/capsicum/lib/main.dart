import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:capsicum_core/capsicum_core.dart';

import 'src/constants.dart';
import 'src/model/account.dart';
import 'src/provider/account_manager_provider.dart';
import 'src/provider/preferences_provider.dart';
import 'src/provider/server_config_provider.dart';
import 'src/provider/timeline_provider.dart';
import 'src/router.dart';
import 'src/service/about_menu_service.dart';
import 'src/service/apns_service.dart';
import 'src/service/fcm_service.dart';
import 'src/service/notification_init.dart';
import 'src/service/notification_label_cache.dart';
import 'src/service/push_failure_recorder.dart';
import 'src/service/push_key_store.dart';
import 'src/service/push_message_dispatcher.dart';
import 'src/service/share_intent_service.dart';
import 'src/util/sentry_tag_hash.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // v1.20 以前に書き込んだ Web Push 鍵は旧 Keychain accessibility のままで、
  // ロック中の NSE 復号が -25308 で弾かれる (#392)。新 accessibility に
  // 書き直す one-shot migration を APNs / push registration の前に同期実行。
  // ただし migration 自体の失敗で起動経路を止めないよう try/catch で握る
  // (Android で起動阻害を起こした実績があるため。#408)。次回起動時に再試行。
  try {
    await PushKeyStore.migrateAccessibilityIfNeeded();
  } catch (e, st) {
    debugPrint('PushKeyStore migration failed: $e\n$st');
  }

  // Register the APNs MethodChannel handler before runApp() so that
  // tokens arriving during engine initialization are not dropped.
  ApnsService.initialize();

  // macOS メニューバー「About capsicum」→ Flutter 側ダイアログを開くための
  // MethodChannel handler。Drawer の「capsicum について」と同じ表示に統一。
  if (Platform.isMacOS) {
    AboutMenuService.initialize();
  }

  // FCM バックグラウンド / キル状態で data-only メッセージを受けた際に、
  // 復号 + ローカル通知を走らせるための top-level ハンドラ登録。
  //
  // onBackgroundMessage は **top-level / static の関数 & @pragma('vm:entry-point')**
  // 必須（firebase_messaging が別 isolate から再エントリするため）。クラス
  // メソッドや匿名関数では silent fail する。
  //
  // 登録は WidgetsFlutterBinding 確立後、runApp() より前の単一ポイントで
  // 行うこと。_initFirebase() は await が入って後段で走るため、その中で
  // 登録するとキル状態からの cold start イベントを拾えない。
  if (Platform.isAndroid) {
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundMessageHandler);
  }

  const dsn = String.fromEnvironment('SENTRY_DSN');

  if (dsn.isNotEmpty) {
    // Linux / Windows の sentry-native はデフォルトで CWD 直下に
    // .sentry-native/ を作る (#496)。CWD は AppImage 起動経路で不定
    // (ターミナル起動なら repo dir、デスクトップ起動なら $HOME 等) のため、
    // path_provider の getApplicationSupportDirectory() で得られる OS 規約
    // 準拠の app data ディレクトリに明示的に固定する。Linux では
    // ~/.local/share/capsicum/、Windows MSIX では %LOCALAPPDATA%\Packages\
    // <PFN>\LocalCache\... に着地し、AppRun wrapper のログ出力先
    // (~/.local/share/capsicum/logs/) と同じディレクトリ階層に揃う。
    String? sentryNativeDbPath;
    if (Platform.isLinux || Platform.isWindows) {
      try {
        final supportDir = await getApplicationSupportDirectory();
        sentryNativeDbPath = '${supportDir.path}/.sentry-native';
      } catch (e, st) {
        // path_provider 失敗時は nativeDatabasePath を未設定のままにし、
        // sentry-native のフォールバック (CWD 直下) に任せる。起動経路を
        // 止める要件ではない。
        debugPrint('getApplicationSupportDirectory failed: $e\n$st');
      }
    }
    await SentryFlutter.init((options) {
      options.dsn = dsn;
      options.tracesSampleRate = 1.0;
      options.environment = const String.fromEnvironment(
        'SENTRY_ENV',
        defaultValue: 'debug',
      );
      options.beforeSend = _scrubEvent;
      if (sentryNativeDbPath != null) {
        options.nativeDatabasePath = sentryNativeDbPath;
      }
    }, appRunner: () => _startApp());
    // Linux / Windows 固有の crashpad_handler 不発 (MSIX の AppContainer 制限
    // や AppRun 経由の長 path) を Sentry initial event から切り分けられるよう、
    // 解決済みの sentry-native database path を breadcrumb に積んでおく。
    if (sentryNativeDbPath != null) {
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'sentry.native',
          message: 'database_path resolved',
          data: {'path': sentryNativeDbPath},
          level: SentryLevel.info,
        ),
      );
    }
  } else {
    _startApp();
  }
}

FutureOr<SentryEvent?> _scrubEvent(SentryEvent event, Hint hint) {
  final request = event.request;
  if (request != null) {
    final headers = Map<String, String>.from(request.headers);
    for (final name in _sensitiveHeaderNames) {
      if (headers.containsKey(name)) headers[name] = '[Filtered]';
    }

    // SentryRequest.data は getter-only のため、scrub 後の値を差し替えるには
    // 新しい SentryRequest で request ごと置き換える（copyWith は deprecated）。
    event.request = SentryRequest(
      url: request.url,
      method: request.method,
      queryString: request.queryString,
      cookies: request.cookies,
      fragment: request.fragment,
      apiTarget: request.apiTarget,
      data: _scrubRequestData(request.data),
      headers: headers,
      env: request.env,
    );
  }

  // SentryDio（将来有効化時）は breadcrumb.data に http.request_headers /
  // http.request_body を載せる。request / response の両側からクレデンシャル
  // が漏れないよう、同じキーセットで scrub する。
  final breadcrumbs = event.breadcrumbs;
  if (breadcrumbs != null && breadcrumbs.isNotEmpty) {
    event.breadcrumbs = breadcrumbs.map(_scrubBreadcrumb).toList();
  }

  return event;
}

const _sensitiveHeaderNames = ['Authorization', 'X-Relay-Secret'];

Breadcrumb _scrubBreadcrumb(Breadcrumb b) {
  final data = b.data;
  var changed = false;
  Map<String, dynamic>? scrubbedData;

  if (data != null && data.isNotEmpty) {
    final copy = Map<String, dynamic>.from(data);
    for (final entry in copy.entries.toList()) {
      final key = entry.key;
      final value = entry.value;
      // ヘッダーマップ（request_headers / response_headers / headers）をスクラブ
      if (key.toLowerCase().contains('header') && value is Map) {
        final headerCopy = Map<String, dynamic>.from(value);
        var headerChanged = false;
        for (final name in _sensitiveHeaderNames) {
          for (final hk in headerCopy.keys.toList()) {
            if (hk.toString().toLowerCase() == name.toLowerCase()) {
              headerCopy[hk] = '[Filtered]';
              headerChanged = true;
            }
          }
        }
        if (headerChanged) {
          copy[key] = headerCopy;
          changed = true;
        }
      }
      // body マップ / JSON 文字列をスクラブ（既存の _scrubRequestData を流用）
      if (key.toLowerCase().contains('body') ||
          key.toLowerCase().contains('data')) {
        final scrubbed = _scrubRequestData(value);
        if (!identical(scrubbed, value)) {
          copy[key] = scrubbed;
          changed = true;
        }
      }
      // URL 系フィールド (sentry_dio の `url`、HTTP breadcrumb の
      // `to`、独自に詰めた `endpoint` 等) に capsicum-relay の
      // `/push/{push_token}` が混入し得るため、path 末尾セグメントをマスクする。
      if (value is String && _isUrlLikeFieldName(key.toString())) {
        final scrubbed = _scrubRelayPushUrl(value);
        if (scrubbed != value) {
          copy[key] = scrubbed;
          changed = true;
        }
      }
    }
    if (changed) scrubbedData = copy;
  }

  // breadcrumb.message にも生 URL が載ることがある (例: log カテゴリの
  // breadcrumb に "POST https://relay.../push/<token>" のような行)。
  String? newMessage = b.message;
  if (b.message != null) {
    final scrubbed = _scrubRelayPushUrl(b.message!);
    if (scrubbed != b.message) {
      newMessage = scrubbed;
      changed = true;
    }
  }

  if (!changed) return b;
  // Breadcrumb.copyWith は deprecated のため、新しいインスタンスを構築する
  // （SentryRequest と同じ扱い）。
  return Breadcrumb(
    message: newMessage,
    timestamp: b.timestamp,
    category: b.category,
    data: scrubbedData ?? data,
    level: b.level,
    type: b.type,
  );
}

bool _isUrlLikeFieldName(String key) {
  final lower = key.toLowerCase();
  return lower == 'url' ||
      lower == 'endpoint' ||
      lower == 'to' ||
      lower == 'from' ||
      lower.endsWith('_url') ||
      lower.endsWith('.url');
}

// `/push/<push_token>` の `<push_token>` 部分を `[Filtered]` に置換する。
// path 区切り (`/`)、クエリ (`?`)、フラグメント (`#`)、空白 / 引用符 / 行終端
// に当たるまでを 1 トークンとして扱う。
final _relayPushTokenPattern = RegExp(r'/push/[^/?#\s"\\]+');

String _scrubRelayPushUrl(String input) {
  return input.replaceAll(_relayPushTokenPattern, '/push/[Filtered]');
}

/// Mastodon の `subscribePush` は FormData を渡すため、キーが
/// `subscription[keys][p256dh]` のようにブラケット表記になる。Misskey は
/// JSON body（`i`）、relay は JSON body（`token`）。いずれも substring
/// マッチで拾えるよう名前リストとパターンマッチの二段構えにする。
///
/// 返り値は新しい値（Sentry request data は immutable なので元を直接
/// 書き換えられない）。該当なしの場合は受け取った値をそのまま返す。
Object? _scrubRequestData(Object? data) {
  if (data is Map) {
    final copy = Map<String, dynamic>.from(data);
    for (final key in copy.keys.toList()) {
      if (_isSensitiveFieldName(key.toString())) copy[key] = '[Filtered]';
    }
    return copy;
  }
  if (data is String) {
    // 文字列 body は JSON 化された relay / Misskey リクエストの可能性。
    // パースできれば scrub して再シリアライズ、できなければそのまま。
    try {
      final parsed = jsonDecode(data);
      if (parsed is Map) {
        final copy = Map<String, dynamic>.from(parsed);
        var changed = false;
        for (final key in copy.keys.toList()) {
          if (_isSensitiveFieldName(key)) {
            copy[key] = '[Filtered]';
            changed = true;
          }
        }
        if (changed) return jsonEncode(copy);
      }
    } catch (_) {}
  }
  return data;
}

bool _isSensitiveFieldName(String key) {
  const names = [
    'i', // Misskey access token
    'access_token',
    'refresh_token',
    'token', // FCM / APNs device token in relay register
    'client_secret', // OAuth completeLogin の exchangeExtra (#528 manual fallback)
    'p256dh', // Web Push ECDH public key
    'auth', // Web Push auth secret
    'endpoint', // push_token が URL に埋め込まれた relay endpoint
    'publickey', // Misskey sw/register (VAPID / subscription 公開鍵)
    'privatekey', // 万一リクエストに載った場合の保険
  ];
  final lower = key.toLowerCase();
  // 完全一致または末尾一致（FormData の subscription[keys][p256dh] 等）
  return names.any(
    (n) => lower == n || lower.endsWith('[$n]') || lower.endsWith('.$n'),
  );
}

void _startApp() {
  // DSN 空ビルド (個人ビルド・CI debug 等で SENTRY_DSN 未設定) では
  // SentryFlutter.init が走らず、FlutterError.onError と
  // PlatformDispatcher.onError が未設定のままになり、Dart エラーが完全に
  // 飲まれる (#498)。最低限 stderr (= Linux AppImage の AppRun ログ) に
  // 流れるよう、未設定の場合だけ既定ハンドラを入れる。Sentry 経路では
  // Sentry が自前で設定済なので ??= で上書きを避ける。
  FlutterError.onError ??= FlutterError.presentError;
  PlatformDispatcher.instance.onError ??= (e, st) {
    debugPrint('Uncaught: $e\n$st');
    return true;
  };

  runApp(const ProviderScope(child: CapsicumApp()));

  // バックグラウンド isolate / NSE が記録した復号失敗等を Sentry に吸い上げる
  // (#366)。SentryFlutter.init より後に走るのでこの位置に配置している。
  unawaited(_flushPushFailureRecord());

  // Firebase / FCM 初期化（Android）。スプラッシュ画面でプッシュ登録前に await する。
  firebaseReady = _initFirebase();

  // Initialize notifications after the widget tree is built so that
  // the permission dialog on iOS does not block rendering.
  // `payload` は将来通知ごとにアカウントを埋める可能性があるため、
  // 受けた文字列をそのまま account-aware routing に委譲する（現状は null）。
  notificationSubsystem.initialize(
    onTap: (payload) => _routeFromNotificationPayload(payload),
  );

  // iOS: APNs タップはネイティブ側で userInfo を乗せて送ってくる。Dart 側では
  // ストリーム経由で account-aware routing に委譲する。cold start 時は
  // AppDelegate 側でバッファされ、engine 起動後に発火する。
  ApnsService.onNotificationTap.listen(
    (userInfo) => _routeFromNotificationUserInfo(userInfo),
  );

  // Check for shared text from external apps (e.g. Spotify, Apple Music).
  // The result is stored in pendingSharedText and consumed by SplashScreen
  // after session restoration completes.
  shareIntentReady = _consumeSharedText();
}

/// バックグラウンド isolate / iOS NSE が記録したプッシュ復号失敗等を
/// 1 件にまとめて Sentry へ吸い上げる (#366)。Sentry が初期化されていない
/// 場合（DSN 未設定）は何もしない。エラーは握りつぶす（観測機構が本体を
/// 落とさない）。
Future<void> _flushPushFailureRecord() async {
  try {
    final record = await PushFailureRecorder.consume();
    if (record == null) return;
    if (Sentry.isEnabled) {
      await Sentry.captureMessage(
        'push.background_failure: ${record.code} (count=${record.count})',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('service', 'push_failure_recorder');
          scope.setTag('push.failure.code', record.code);
          scope.setTag('push.failure.count', record.count.toString());
          scope.setTag('push.failure.last_at', record.at.toIso8601String());
          // #436: code ごとに別グループへ分割する。デフォルトでは
          // captureMessage の文面が固定（テンプレート文字列）でも Sentry が
          // 単一グループにまとめてしまい、nse.no_keys / nse.decrypt_failed /
          // dispatch.* の優先度判定が混ざる。
          scope.fingerprint = ['push.failure', record.code];
          // #376: 切り分けコンテキスト。host で自前/他鯖、encoding で暗号化
          // 方式の偏り、elapsedMs でタイムアウト由来か即時失敗かを Sentry の
          // tag/extra で見られるようにする。bg_handler.failed のように context
          // が取れない経路では欠落するので、null 時はタグごと出さない。
          if (record.host != null) {
            scope.setTag('push.host', record.host!);
          }
          if (record.encoding != null) {
            scope.setTag('push.encoding', record.encoding!);
          }
          if (record.elapsedMs != null) {
            scope.setContexts('push', {'nse_elapsed_ms': record.elapsedMs});
          }
          // #436: nse.no_keys 切り分け用。Keychain OSStatus と試行プレフィックス。
          if (record.keychainStatus != null) {
            scope.setTag(
              'push.keychain.status',
              record.keychainStatus.toString(),
            );
          }
          if (record.triedPrefixes != null) {
            scope.setTag('push.keychain.tried', record.triedPrefixes!);
          }
          // #436: nse.decrypt_failed 切り分け用。WebPushDecryptor / CryptoKit
          // が投げた error の type + case 名。Misskey 限定の decrypt_failed
          // が header 系か鍵不一致 (CryptoKit authenticationFailure) かを分ける。
          if (record.decryptError != null) {
            scope.setTag('push.decrypt.error', record.decryptError!);
            // 二次タグで Sentry 検索を簡素化する (#436 v1.25 observation):
            //   - auth_failure: 鍵不一致 (Misskey サーバー側に保存された
            //     p256dh と capsicum 側の鍵がずれているケース)
            //   - header: WebPushError 系 (relay → NSE の payload 欠損)
            //   - other: 上記外
            final kind = _classifyDecryptErrorKind(record.decryptError!);
            scope.setTag('push.decrypt.kind', kind);
          }
        },
      );
    }
    debugPrint(
      'capsicum: push.failure_recorder: flushed ${record.code} '
      '(count=${record.count}, at=${record.at.toIso8601String()}, '
      'host=${record.host}, encoding=${record.encoding}, '
      'elapsedMs=${record.elapsedMs}, '
      'keychainStatus=${record.keychainStatus}, '
      'triedPrefixes=${record.triedPrefixes}, '
      'decryptError=${record.decryptError})',
    );
  } catch (_) {
    // ignore
  }
}

/// 通知タップで通知タブへ遷移する共通経路。[accountString] は `username@host`
/// 形式で、該当するサインイン済みアカウントがあれば遷移前に切り替える。
/// 一致しない（ログアウト済み等）場合は現在アカウントのままタブ遷移のみ行う。
///
/// cold-start 通知タップでは以下の 2 段待ちを行ってから go('/home') する：
/// 1. Navigator が立ち上がるまで（rootNavigatorKey.currentContext）
/// 2. [sessionsRestoredProvider] が true になるまで（restoreSessions は
///    1 アカウントずつ state 更新するため、単に accounts.isNotEmpty では
///    途中 state を拾って宛先アカウントを取りこぼす可能性がある）
///
/// この 2 段待ちがないと、restore 中に go('/home') → 認証 redirect で /server
/// に飛ばされ、SplashScreen が unmount して `!mounted` リターンで以降の
/// 正規ルーティングが空振り、ユーザーがサーバー選択画面に取り残される。
/// `record.decryptError` の type+case 名から二次分類タグを生成する (#436 v1.25)。
///
/// NSE が記録する文字列は `"\(type(of: error)).\(String(describing: error))"`
/// の形 (例: `CryptoKitError.authenticationFailure`,
/// `WebPushError.invalidKeyId`, `WebPushError.payloadTruncated`)。Sentry
/// 検索で個別の文字列を OR で並べると煩雑なため、3 値に丸めた `push.decrypt.kind`
/// を一緒に出して filter / facet をしやすくする。
@visibleForTesting
String classifyDecryptErrorKind(String reason) {
  final lower = reason.toLowerCase();
  if (lower.contains('authenticationfailure')) {
    return 'auth_failure';
  }
  if (lower.contains('webpusherror') || lower.contains('payloadtruncated')) {
    return 'header';
  }
  return 'other';
}

String _classifyDecryptErrorKind(String reason) =>
    classifyDecryptErrorKind(reason);

/// 通知タップで届く JSON payload (push_message_dispatcher が encode) を解釈し、
/// type=newChatMessage なら `/chat/user/<userId>` へ直行、それ以外は通知タブへ
/// 遷移する (#440)。後方互換: payload が JSON でなく裸の `username@host` だった
/// 場合 (v1.24.x 以前にスケジュールされて残っている通知) は account-only として扱う。
void _routeFromNotificationPayload(String? payload) {
  if (payload == null || payload.isEmpty) {
    _routeToNotificationsTab(null);
    return;
  }
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      final account = decoded['account'] as String?;
      final type = decoded['type'] as String?;
      final userId = decoded['userId'] as String?;
      if (type == 'newChatMessage' && userId != null && userId.isNotEmpty) {
        _routeToChatThread(account, userId);
        return;
      }
      _routeToNotificationsTab(account);
      return;
    }
  } catch (_) {
    // JSON でない → legacy 形式として扱う。
  }
  _routeToNotificationsTab(payload);
}

/// iOS APNs タップの userInfo dict から JSON 経路と同じ判定を行う。
void _routeFromNotificationUserInfo(Map<String, dynamic> userInfo) {
  final account = userInfo['account'] as String?;
  final type = userInfo['type'] as String?;
  final userId = userInfo['userId'] as String?;
  if (type == 'newChatMessage' && userId != null && userId.isNotEmpty) {
    _routeToChatThread(account, userId);
    return;
  }
  _routeToNotificationsTab(account);
}

/// 通知タップで該当 DM スレッドを開く経路 (#440)。account を必要に応じて切り替え、
/// `getUserById(userId)` で User を解決してから `/chat/user/:userId` に push する。
/// session restore 完了と Navigator 確立を待つ点は [_routeToNotificationsTab] と
/// 同じ 2 段待ち構造を踏襲。
void _routeToChatThread(
  String? accountString,
  String userId, {
  int attempt = 0,
}) {
  const maxAttempts = 3600;
  final context = rootNavigatorKey.currentContext;
  if (context == null) {
    if (attempt >= maxAttempts) return;
    WidgetsBinding.instance.scheduleFrameCallback(
      (_) => _routeToChatThread(accountString, userId, attempt: attempt + 1),
    );
    return;
  }
  final container = ProviderScope.containerOf(context);
  if (!container.read(sessionsRestoredProvider)) {
    if (attempt >= maxAttempts) return;
    WidgetsBinding.instance.scheduleFrameCallback(
      (_) => _routeToChatThread(accountString, userId, attempt: attempt + 1),
    );
    return;
  }
  final accounts = container.read(accountManagerProvider).accounts;
  if (accounts.isEmpty) return;
  if (accountString != null) {
    final matched = _findAccountByString(accounts, accountString);
    if (matched != null) {
      container.read(accountManagerProvider.notifier).switchAccount(matched);
    }
  }
  // adapter 切替後の `getUserById` を非同期に実行し、解決後に push。
  unawaited(() async {
    final adapter = container.read(currentAdapterProvider);
    if (adapter == null || adapter is! ChatSupport) {
      // 想定外: chat 非対応アカウントへ切り替わった等。通知タブにフォールバック。
      _routeToNotificationsTab(accountString);
      return;
    }
    try {
      final user = await adapter.getUserById(userId);
      if (!context.mounted) return;
      // /home に揃えてから push しないと Drawer / 戻る挙動が崩れるので、
      // 現在 location が /splash 等なら home に遷移してから push する。
      final router = GoRouter.of(context);
      final currentLocation = router.state.matchedLocation;
      if (currentLocation != '/home') {
        router.go('/home');
      }
      router.push('/chat/user/$userId', extra: user);
    } catch (e, st) {
      // user 解決失敗 (削除済み・通信エラー等) は通知タブにフォールバック。
      Sentry.captureException(
        e,
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('notification.routing', 'chat.user_resolve_failed');
          scope.fingerprint = ['notification.routing.chat.failed'];
        },
      );
      _routeToNotificationsTab(accountString);
    }
  }());
}

void _routeToNotificationsTab(String? accountString, {int attempt = 0}) {
  // 上限: restoreSessions は 1 アカウントあたり getMyself + mulukhiya probe
  // + timeline availability probe を走らせるため、低速回線 + 多アカウント
  // 環境では 10〜30 秒かかりうる。3600 フレーム（≒ 60 秒 @60fps）を上限に
  // 設定し、現実的な restore 時間を十分にカバーしつつ、pathological な
  // Navigator 未確立ケースの暴走も防ぐ。
  const maxAttempts = 3600;

  final context = rootNavigatorKey.currentContext;
  if (context == null) {
    _rescheduleNotificationRoute(accountString, attempt, maxAttempts);
    return;
  }
  final container = ProviderScope.containerOf(context);
  // restore 完了までは accounts.isNotEmpty でも宛先が見つからない可能性が
  // ある。sessionsRestoredProvider が true になるまで待つ。
  if (!container.read(sessionsRestoredProvider)) {
    _rescheduleNotificationRoute(accountString, attempt, maxAttempts);
    return;
  }

  final accounts = container.read(accountManagerProvider).accounts;
  if (accounts.isEmpty) {
    // sessions restore は完了したが有効アカウントなし（全アカウントが
    // ログアウト済み、または初回起動後にプッシュ通知だけ残っていた stale
    // タップ等）。ここで pendingInitialTabProvider を設定して go('/home')
    // を呼ぶと auth redirect で /server に飛ばされた後も pendingTab が
    // 残留し、次回のログイン後に意図せず通知タブが開かれてしまう。
    debugPrint('capsicum: notification: routing dropped — no active accounts');
    return;
  }

  if (accountString != null) {
    final matched = _findAccountByString(accounts, accountString);
    if (matched != null) {
      container.read(accountManagerProvider.notifier).switchAccount(matched);
    }
  }

  // pendingInitialTabProvider は常に立てる。HomeScreen が mount 済みなら
  // rebuild で拾われ、/splash や /eula 経由の導線では遷移完了後の
  // HomeScreen build 時に拾われる。
  container.read(pendingInitialTabProvider.notifier).state =
      const NotificationsTab();

  // 現在 /splash や /eula にいる場合、go('/home') すると EULA 承認チェック
  // や splash の通常導線を飛ばしてしまう。これらのフローは自前で /home に
  // 到達するので、通知ルーティング側で navigate せず pendingTab の設定だけ
  // に留める（後から到達した HomeScreen が pendingTab を拾う）。
  final router = GoRouter.of(context);
  final currentLocation = router.state.matchedLocation;
  if (currentLocation != '/home' &&
      currentLocation != '/splash' &&
      currentLocation != '/eula') {
    router.go('/home');
  }
}

/// [_routeToNotificationsTab] の再スケジュール。attempt 上限超過で諦める。
void _rescheduleNotificationRoute(
  String? accountString,
  int attempt,
  int maxAttempts,
) {
  if (attempt >= maxAttempts) {
    debugPrint(
      'capsicum: notification: routing gave up after $maxAttempts frames',
    );
    // 60 秒空振りは UX バグ (タップで該当画面に遷移しない) だが debugPrint
    // のみで Sentry に上がらず発生頻度・条件が掴めなかった (#513)。
    // payload (= username@host) は #500 の方針に揃えて host + user_hash の
    // 2 タグに分離し、生 username を Sentry に出さない。
    Sentry.captureMessage(
      'notification.routing.gave_up',
      level: SentryLevel.warning,
      withScope: (scope) {
        if (accountString == null) {
          scope.setTag('payload', '<null>');
        } else {
          final atIdx = accountString.indexOf('@');
          if (atIdx > 0 && atIdx < accountString.length - 1) {
            final username = accountString.substring(0, atIdx);
            final host = accountString.substring(atIdx + 1);
            scope.setTag('payload.host', host);
            scope.setTag('payload.user_hash', hashForSentryTag(username));
          } else {
            scope.setTag('payload', '<malformed>');
          }
        }
        scope.setTag('attempts', maxAttempts.toString());
      },
    );
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => _routeToNotificationsTab(accountString, attempt: attempt + 1),
  );
}

Account? _findAccountByString(List<Account> accounts, String accountString) {
  // 'username@host' 形式。capsicum-relay の sub['account'] と同じ。
  final idx = accountString.indexOf('@');
  if (idx <= 0) return null;
  final username = accountString.substring(0, idx);
  final host = accountString.substring(idx + 1);
  for (final a in accounts) {
    if (a.key.username == username && a.key.host == host) return a;
  }
  return null;
}

/// プッシュ通知の宛先アカウントに対応する「ブースト/リノート」ラベルを
/// 解決する。モロヘイヤの `reblog_label` (例: キュアスタ！の "リキュア！")
/// がある場合それを優先し、なければ adapter 種別で分岐する。
String _resolveReblogLabelForAccount(String accountString) {
  final account = _lookupAccount(accountString);
  final mulukhiya = account?.mulukhiya;
  if (mulukhiya?.reblogLabel != null) return mulukhiya!.reblogLabel!;
  return account?.adapter is ReactionSupport ? 'リノート' : 'ブースト';
}

/// プッシュ通知の宛先アカウントに対応する「投稿」ラベルを解決する。
String _resolvePostLabelForAccount(String accountString) {
  final account = _lookupAccount(accountString);
  return account?.mulukhiya?.postLabel ?? '投稿';
}

/// Riverpod コンテナから accountManagerProvider を読んで該当アカウントを返す。
/// コンテナが未確立（ごく初期）の場合は null。
Account? _lookupAccount(String accountString) {
  final context = rootNavigatorKey.currentContext;
  if (context == null) return null;
  final container = ProviderScope.containerOf(context);
  final accounts = container.read(accountManagerProvider).accounts;
  return _findAccountByString(accounts, accountString);
}

/// Shared text received via share intent, waiting to be consumed after login.
String? pendingSharedText;

/// Completes when the share intent check is done.
late final Future<void> shareIntentReady;

/// Completes when Firebase / FCM initialization is done (Android only).
late final Future<void> firebaseReady;

/// FCM onMessageOpenedApp / getInitialMessage の二重発火を抑止する。
/// 端末・ディストリビューションによっては terminated から復帰した場合に
/// 両方が同じ RemoteMessage を配信することがあるため、messageId で dedup。
String? _lastFcmMessageId;

void _handleFcmMessage(RemoteMessage message) {
  final messageId = message.messageId;
  if (messageId != null && messageId == _lastFcmMessageId) {
    debugPrint('capsicum: FCM message dedup hit: $messageId');
    return;
  }
  _lastFcmMessageId = messageId;
  _routeToNotificationsTab(message.data['account'] as String?);
}

/// FCM バックグラウンド / キル状態メッセージ用のトップレベルハンドラ。
///
/// firebase_messaging は data-only メッセージ到着時にこの関数を
/// **別 isolate** で呼び出す。その isolate には main() の実行結果が
/// 残っていないため、Firebase / プラグインレジストリ / 通知プラグインの
/// 初期化をここでもう一度行う必要がある。
///
/// リレーは `notification` ブロックを落として data-only で送る設計に
/// したので、Android バックグラウンド / キル状態でもこのハンドラが発火し、
/// [PushMessageDispatcher.dispatch] で RFC 8291 復号 → ローカル通知表示が
/// 走る。fallback として復号失敗時は従来の「${account} に通知があります」
/// 表示に落とすのは foreground 経路と同じ。
///
/// ラベル（ブースト/リノート/リキュア！・投稿）解決は providers が生きて
/// いないため [NotificationLabelCache]（shared_preferences 永続キャッシュ）
/// から読み取る。未保存アカウント向けには汎用ラベルに落ちる。
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundMessageHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    // タップハンドラはフォアグラウンド側の登録が生きる（OS が通知をタップ
    // された際に app を起動し、main() 経由で再登録される）ため、ここでは
    // no-op を渡してプラグインの初期化だけ成立させる。
    await notificationSubsystem.initialize(onTap: (_) {});
    await PushMessageDispatcher.dispatch(
      message,
      reblogLabelResolver: NotificationLabelCache.readReblog,
      postLabelResolver: NotificationLabelCache.readPost,
    );
  } catch (e, st) {
    debugPrint('capsicum: push.background: handler failed: $e');
    // Sentry はバックグラウンド isolate では init されていないため、
    // ここでは debugPrint のみ。致命的でも UI を落とさない。
    // 復号失敗等は dispatcher 内で個別記録されているが、ここに落ちる
    // 例外（Firebase init・notification plugin 初期化失敗等）は
    // bg_handler.failed として永続化し、次回 main app 起動時に
    // Sentry へ吸い上げる (#366)。
    debugPrintStack(stackTrace: st);
    await PushFailureRecorder.record(PushFailureRecorder.codeHandlerFailed);
  }
}

Future<void> _initFirebase() async {
  if (!Platform.isAndroid) return;
  try {
    debugPrint('capsicum: Firebase.initializeApp starting');
    await Firebase.initializeApp();
    debugPrint('capsicum: Firebase.initializeApp done, starting FCM');
    await FcmService.initialize();
    debugPrint('capsicum: FCM init done');

    // Android: FCM の system-tray 通知タップは flutter_local_notifications の
    // onTap を経由しない（OS が直接表示するため）。
    // onMessageOpenedApp は background / foreground 状態でのタップ、
    // getInitialMessage は terminated 状態からの cold start タップを拾う。
    FirebaseMessaging.onMessageOpenedApp.listen(_handleFcmMessage);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      _handleFcmMessage(initial);
    }

    // フォアグラウンド配信: relay は data-only で送るため、OS による自動表示
    // は一切起きない。復号してローカル通知を出す (#336 Phase 2)。
    // バックグラウンド / キル時は main() 頭で登録した
    // [_firebaseBackgroundMessageHandler] 側で処理する (#336 Phase 3)。
    FirebaseMessaging.onMessage.listen((message) {
      debugPrint(
        'capsicum: push.onMessage fired: data keys=${message.data.keys.toList()}',
      );
      unawaited(
        PushMessageDispatcher.dispatch(
          message,
          reblogLabelResolver: _resolveReblogLabelForAccount,
          postLabelResolver: _resolvePostLabelForAccount,
        ),
      );
    });
    debugPrint('capsicum: push.onMessage listener registered');
  } catch (e, st) {
    debugPrint('capsicum: Firebase initialization failed: $e');
    Sentry.captureException(
      e,
      stackTrace: st,
      withScope: (scope) {
        scope.setTag('service', 'firebase_init');
      },
    );
  }
}

Future<void> _consumeSharedText() async {
  final text = await ShareIntentService.consumeSharedText();
  if (text != null && text.isNotEmpty) {
    pendingSharedText = text;
  }
}

class CapsicumApp extends ConsumerStatefulWidget {
  const CapsicumApp({super.key});

  @override
  ConsumerState<CapsicumApp> createState() => _CapsicumAppState();
}

class _CapsicumAppState extends ConsumerState<CapsicumApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSharedText();
    }
  }

  Future<void> _checkSharedText() async {
    final text = await ShareIntentService.consumeSharedText();
    if (text != null && text.isNotEmpty) {
      _navigateToCompose(text);
    }
  }

  void _navigateToCompose(String sharedText) {
    final context = rootNavigatorKey.currentContext;
    if (context != null) {
      GoRouter.of(context).go('/compose', extra: {'sharedText': sharedText});
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final seedColor = ref.watch(themeSeedColorProvider);
    final themeMode = ref.watch(themeModeProvider);
    final darkVariant = ref.watch(darkSurfaceVariantProvider);
    final darkSurface = darkSurfaceColor(darkVariant);
    final darkTextVariant = ref.watch(darkTextColorProvider);
    final darkText = darkTextColor(darkTextVariant);

    var darkScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    if (darkSurface != null) {
      darkScheme = darkScheme.copyWith(
        surface: darkSurface,
        surfaceContainer: darkSurface,
        surfaceContainerLow: darkSurface,
        surfaceContainerLowest: darkSurface,
        surfaceContainerHigh: Color.lerp(darkSurface, Colors.white, 0.05)!,
        surfaceContainerHighest: Color.lerp(darkSurface, Colors.white, 0.08)!,
      );
    }
    if (darkText != null) {
      darkScheme = darkScheme.copyWith(
        onSurface: darkText,
        onSurfaceVariant: Color.lerp(darkText, Colors.grey, 0.3)!,
      );
    }

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: AppConstants.appName,
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(colorScheme: darkScheme, useMaterial3: true),
      themeMode: themeMode,
      builder: (context, child) {
        final fontScale = ref.watch(fontScaleProvider);
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(fontScale)),
          child: child!,
        );
      },
      routerConfig: router,
    );
  }
}
