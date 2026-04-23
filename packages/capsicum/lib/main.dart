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
import 'src/service/notification_label_cache.dart';
import 'src/service/push_message_dispatcher.dart';
import 'src/service/share_intent_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register the APNs MethodChannel handler before runApp() so that
  // tokens arriving during engine initialization are not dropped.
  ApnsService.initialize();

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
  if (data == null || data.isEmpty) return b;

  final copy = Map<String, dynamic>.from(data);
  var changed = false;
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
  }

  if (!changed) return b;
  // Breadcrumb.copyWith は deprecated のため、新しいインスタンスを構築する
  // （SentryRequest と同じ扱い）。
  return Breadcrumb(
    message: b.message,
    timestamp: b.timestamp,
    category: b.category,
    data: copy,
    level: b.level,
    type: b.type,
  );
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
    await NotificationInit.initialize(onTap: (_) {});
    await PushMessageDispatcher.dispatch(
      message,
      reblogLabelResolver: NotificationLabelCache.readReblog,
      postLabelResolver: NotificationLabelCache.readPost,
    );
  } catch (e, st) {
    debugPrint('capsicum: push.background: handler failed: $e');
    // Sentry はバックグラウンド isolate では init されていないため、
    // ここでは debugPrint のみ。致命的でも UI を落とさない。
    debugPrintStack(stackTrace: st);
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
