import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'src/router.dart';
import 'src/service/notification_init.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await NotificationInit.initialize(
    onTap: (response) {
      final context = rootNavigatorKey.currentContext;
      if (context != null) {
        GoRouter.of(context).go('/notifications');
      }
    },
  );

  runApp(const ProviderScope(child: CapsicumApp()));
}

class CapsicumApp extends ConsumerWidget {
  const CapsicumApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'capsicum',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
