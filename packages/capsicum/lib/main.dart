import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'src/constants.dart';
import 'src/provider/preferences_provider.dart';
import 'src/provider/server_config_provider.dart';
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
  if (request != null) {
    if (request.headers.containsKey('Authorization')) {
      request.headers['Authorization'] = '[Filtered]';
    }
    final data = request.data;
    if (data is Map && data.containsKey('i')) {
      data['i'] = '[Filtered]';
    }
  }
  return event;
}

void _startApp() {
  runApp(const ProviderScope(child: CapsicumApp()));

  // Firebase / FCM 初��化（Android）。スプラッシュ画面でプッシュ登録前に await する。
  firebaseReady = _initFirebase();

  // Initialize notifications after the widget tree is built so that
  // the permission dialog on iOS does not block rendering.
  NotificationInit.initialize(
    onTap: (response) {
      final context = rootNavigatorKey.currentContext;
      if (context != null) {
        GoRouter.of(context).go('/notifications');
      }
    },
  );

  // Check for shared text from external apps (e.g. Spotify, Apple Music).
  // The result is stored in pendingSharedText and consumed by SplashScreen
  // after session restoration completes.
  shareIntentReady = _consumeSharedText();
}

/// Shared text received via share intent, waiting to be consumed after login.
String? pendingSharedText;

/// Completes when the share intent check is done.
late final Future<void> shareIntentReady;

/// Completes when Firebase / FCM initialization is done (Android only).
late final Future<void> firebaseReady;

Future<void> _initFirebase() async {
  if (!Platform.isAndroid) return;
  try {
    // ignore: avoid_print
    print('capsicum: Firebase.initializeApp starting');
    await Firebase.initializeApp();
    // ignore: avoid_print
    print('capsicum: Firebase.initializeApp done, starting FCM');
    await FcmService.initialize();
    // ignore: avoid_print
    print('capsicum: FCM init done');
  } catch (e) {
    // ignore: avoid_print
    print('capsicum: Firebase initialization failed: $e');
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
