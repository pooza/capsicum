import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../main.dart'
    show appLaunchStopwatch, firebaseReady, pendingSharedText, shareIntentReady;
import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/entitlement_status_provider.dart';
import '../../provider/platform_providers.dart';
import '../../service/entitlement_notice_service.dart';
import '../../service/push_registration_service.dart';
import '../../util/exception_scrub.dart';
import '../../util/startup_trace.dart';
import 'eula_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _restoreSessions();
  }

  Future<void> _restoreSessions() async {
    var skippedAccounts = 0;
    final restoreSw = Stopwatch()..start();
    try {
      skippedAccounts = await ref
          .read(accountManagerProvider.notifier)
          .restoreSessions();
    } catch (e, st) {
      debugLogException('capsicum: failed to restore sessions', e, st);
    }
    restoreSw.stop();

    // #716 計測: 復元の所要 (restore_ms) と起動からの経過 (since_launch_ms) を
    // 残す。restore_ms は #716 並列化の直接指標、since_launch_ms は「起動 →
    // 復元完了」の体感前段。サーバー応答に左右されないので時間帯をまたいだ
    // 前後比較に使える。
    final accountCount = ref.read(accountManagerProvider).accounts.length;
    debugPrint(
      'capsicum: startup: sessions restored in '
      '${restoreSw.elapsedMilliseconds}ms '
      '(since_launch=${appLaunchStopwatch.elapsedMilliseconds}ms '
      'accounts=$accountCount skipped=$skippedAccounts)',
    );
    // 起動計測 (#716): transaction duration = restore_ms（復元の所要・サーバー
    // 非依存）。since_launch_ms は measurement で持つ。
    recordStartupPhase(
      'app.startup.restore',
      durationMs: restoreSw.elapsedMilliseconds,
      measurementsMs: {
        'since_launch_ms': appLaunchStopwatch.elapsedMilliseconds,
      },
      data: {'accounts': accountCount, 'skipped': skippedAccounts},
    );
    if (!mounted) return;

    // restoreSessions() が完走した。通知タップ routing が accounts の
    // インクリメンタル更新と race しないよう、完了 signal を立てる。
    ref.read(sessionsRestoredProvider.notifier).state = true;

    // Firebase 初期化を待ってからプッシュ通知登録（ベストエフォート）。
    // 起動時点のアカウント一覧をクロージャーで固定すると、Firebase 初期化中
    // にユーザーがログアウトしたアカウントまで再登録してしまうため、登録
    // 実行時に最新状態を ProviderContainer 経由で再取得する。
    //
    // registerAllAccounts を await してから startTokenRefreshListener を
    // 起動する：初回登録の途中でトークン rotation が発火すると、in-flight
    // ガードに引っかかった未完 Future が古いトークンの結果を成功と
    // 報告してしまう race を避ける。
    //
    // listener は accounts 数に関わらず登録する。未ログインで起動 → 同セッ
    // ション中にログイン、の導線でも以降のトークン rotation で再登録が
    // 発火するようにするため（broadcast stream は過去 emit を配信しない）。
    final container = ProviderScope.containerOf(context, listen: false);
    firebaseReady.then((_) async {
      final latest = container.read(accountManagerProvider).accounts;
      if (latest.isNotEmpty) {
        // 登録より先に、前回の登録に使ったデバイストークンと突き合わせる
        // (#937)。再起動をまたいだトークン変化は startTokenRefreshListener の
        // 観測範囲外（in-memory 値が null から始まるので「変化」にならない）
        // なので、ここで拾わないと上流に古い購読が孤児として残り続ける。
        await PushRegistrationService.reconcileDeviceToken(latest);
        await PushRegistrationService.registerAllAccounts(latest);
        // ⚠⚠ **未払いはプッシュでは知らせられない** (#1123)。relay が
        // `/push` を拒んでいる状態なので、**relay を通さないローカル通知**で
        // 出す。⚠ 登録のあと（relay へ問い合わせた結果が要る）。
        await _notifyUnpaidEntitlement(container, latest);
      }
      PushRegistrationService.startTokenRefreshListener(
        () => container.read(accountManagerProvider).accounts,
      );
    });

    if (skippedAccounts > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('セキュリティキーの変更により$skippedAccounts件のアカウントで再ログインが必要です'),
            duration: const Duration(seconds: 5),
          ),
        );
      });
    }

    final prefs = await SharedPreferences.getInstance();
    final eulaAccepted = prefs.getBool(eulaAcceptedKey) ?? false;
    if (!mounted) return;

    // Wait for the share intent check to complete before deciding the route.
    await shareIntentReady;
    if (!mounted) return;

    final accountState = ref.read(accountManagerProvider);
    // オンラインで使えるアカウントがあるか（共有 → compose の可否判定用）。
    final hasAccount = accountState.current != null;
    // ログイン済みか（/home か /server かの分岐用）。到達不能でオフライン保持中の
    // アカウントも「ログイン済み」に含め、サーバー停止 / 再構築中に /server（ログ
    // イン画面）へ飛ばして「ログアウトされた」ように見せない (#792)。判定は
    // router の redirect と共有する (#917)。
    final hasSession = accountState.hasSession;

    // If a share intent is pending and the user is logged in, go to compose.
    final shared = pendingSharedText;
    if (shared != null && hasAccount) {
      pendingSharedText = null;
      final nextRoute = '/compose';
      final extra = <String, dynamic>{'sharedText': shared};
      if (!eulaAccepted) {
        // EULA must be accepted first; shared text is lost in this edge case.
        context.go('/eula', extra: '/home');
      } else {
        context.go(nextRoute, extra: extra);
      }
      return;
    }

    final nextRoute = hasSession ? '/home' : '/server';
    if (!eulaAccepted) {
      context.go('/eula', extra: nextRoute);
    } else {
      context.go(nextRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/images/logo.png', height: 64),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

/// 未払いなら起動時にローカル通知を出す (#1123)。
///
/// ⚠⚠ **ベストエフォート。**ここで何が起きても起動を止めない —— 利用権の案内は
/// 起動の前提ではない。⚠ 失敗しても Sentry へは送らない（relay へ届かない回は
/// 圏外でも起きるので、ノイズにしかならない）。
Future<void> _notifyUnpaidEntitlement(
  ProviderContainer container,
  List<Account> accounts,
) async {
  try {
    await container.read(entitlementStatusProvider.notifier).refresh();
    final status = container.read(entitlementStatusProvider);
    await EntitlementNoticeService.notifyIfNeeded(
      view: status.view,
      hasPreset: PushRegistrationService.hasPresetAmong(accounts),
      notifications: container.read(notificationSubsystemProvider),
      prefs: await SharedPreferences.getInstance(),
    );
  } catch (_) {
    // ⚠ 握りつぶす（上の doc のとおり）。
  }
}
