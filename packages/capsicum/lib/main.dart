import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:capsicum_core/capsicum_core.dart';

import 'src/constants.dart';
import 'src/model/account.dart';
import 'src/provider/account_manager_provider.dart';
import 'src/provider/preferences_provider.dart';
import 'src/provider/server_config_provider.dart';
import 'src/provider/timeline_provider.dart';
import 'src/router.dart';
import 'src/service/apns_service.dart';
import 'src/service/fcm_service.dart';
import 'src/service/notification_init.dart';
import 'src/service/share_intent_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register the APNs MethodChannel handler before runApp() so that
  // tokens arriving during engine initialization are not dropped.
  ApnsService.initialize();

  const dsn = String.fromEnvironment('SENTRY_DSN');

  if (dsn.isNotEmpty) {
    await SentryFlutter.init((options) {
      options.dsn = dsn;
      options.tracesSampleRate = 1.0;
      options.environment = const String.fromEnvironment(
        'SENTRY_ENV',
        defaultValue: 'debug',
      );
      options.beforeSend = _scrubEvent;
    }, appRunner: () => _startApp());
  } else {
    _startApp();
  }
}

FutureOr<SentryEvent?> _scrubEvent(SentryEvent event, Hint hint) {
  final request = event.request;
  if (request == null) return event;

  final headers = Map<String, String>.from(request.headers);
  const sensitiveHeaders = ['Authorization', 'X-Relay-Secret'];
  for (final name in sensitiveHeaders) {
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
  return event;
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
  runApp(const ProviderScope(child: CapsicumApp()));

  // Firebase / FCM 初期化（Android）。スプラッシュ画面でプッシュ登録前に await する。
  firebaseReady = _initFirebase();

  // Initialize notifications after the widget tree is built so that
  // the permission dialog on iOS does not block rendering.
  // `response.payload` は将来通知ごとにアカウントを埋める可能性があるため、
  // 受けた文字列をそのまま account-aware routing に委譲する（現状は null）。
  NotificationInit.initialize(
    onTap: (response) => _routeToNotificationsTab(response.payload),
  );

  // iOS: APNs タップはネイティブ側で userInfo を乗せて送ってくる。Dart 側では
  // ストリーム経由で account-aware routing に委譲する。cold start 時は
  // AppDelegate 側でバッファされ、engine 起動後に発火する。
  ApnsService.onNotificationTap.listen(
    (userInfo) => _routeToNotificationsTab(userInfo['account'] as String?),
  );

  // Check for shared text from external apps (e.g. Spotify, Apple Music).
  // The result is stored in pendingSharedText and consumed by SplashScreen
  // after session restoration completes.
  shareIntentReady = _consumeSharedText();
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
