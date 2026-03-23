import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'src/constants.dart';
import 'src/provider/preferences_provider.dart';
import 'src/provider/server_config_provider.dart';
import 'src/router.dart';
import 'src/service/notification_init.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
}

class CapsicumApp extends ConsumerWidget {
  const CapsicumApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
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
        colorScheme: ColorScheme.fromSeed(
          seedColor: ref.watch(themeSeedColorProvider),
        ),
        useMaterial3: true,
      ),
      builder: (context, child) {
        final fontScale = ref.watch(fontScaleProvider);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(fontScale),
          ),
          child: child!,
        );
      },
      routerConfig: router,
    );
  }
}
