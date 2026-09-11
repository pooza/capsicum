import 'dart:io';

import 'package:capsicum/src/router.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// #1057: `/login` の引数を `extra` ではなくクエリで運ぶ。
///
/// ⚠⚠ **go_router は `refreshListenable` が鳴るたびに RouteMatchList を
/// シリアライズ経由で組み直す。**`extraCodec` を渡していないので
/// `json.encoder.convert(extra)` に掛かり、[BackendType]（enum）のような JSON に
/// できない値が 1 つでも入っていると **extra が丸ごと null に落ちる**。すると
/// `/login` のフォールバックが `/server` へ飛ばし、**OAuth の完走を待っている
/// `LoginScreen` がその場で dispose される**。これが「認可は成功しているのに
/// サーバー選択画面に戻る」（#1057 / Sentry CAPSICUM-16）の正体だった。
///
/// ⚠ このファイルの前半は **go_router 側の挙動を固定するもの**。捨てないこと。
/// 挙動が変わったら「クエリで運ぶ」理由が消えるので、そのとき初めて設計を
/// 見直せる。
void main() {
  group('loginLocation / resolveLoginArgs の往復', () {
    test('組み立てて読み直すと同じ値になる', () {
      for (final type in BackendType.values) {
        final args = resolveLoginArgs(
          Uri.parse(
            loginLocation(
              LoginArgs(
                host: 'example.com',
                backendType: type,
                softwareVersion: '2026.9.0',
              ),
            ),
          ),
        );
        expect(args, isNotNull, reason: type.name);
        expect(args!.host, 'example.com');
        expect(args.backendType, type);
        expect(args.softwareVersion, '2026.9.0');
      }
    });

    test('softwareVersion は無くてよい', () {
      final args = resolveLoginArgs(
        Uri.parse(
          loginLocation(
            LoginArgs(host: 'example.com', backendType: BackendType.misskey),
          ),
        ),
      );
      expect(args, isNotNull);
      expect(args!.softwareVersion, isNull);
    });

    test('パスは /login のまま（auth ゲートの判定に効く）', () {
      final uri = Uri.parse(
        loginLocation(
          LoginArgs(host: 'example.com', backendType: BackendType.mastodon),
        ),
      );
      expect(uri.path, '/login');
      // ⚠ auth ゲート（resolveRedirect）は matchedLocation ＝ クエリを含まない
      // パスで判定する。クエリを足したことで未ログイン時に弾かれてはいけない。
      expect(resolveRedirect(isLoggedIn: false, location: uri.path), isNull);
    });

    test('ホストに記号が入っても壊れない', () {
      final args = resolveLoginArgs(
        Uri.parse(
          loginLocation(
            LoginArgs(
              host: 'xn--eckwd4c7c.example.com',
              backendType: BackendType.misskey,
              softwareVersion: '4.7.1+bshockdon (build 1)',
            ),
          ),
        ),
      );
      expect(args!.host, 'xn--eckwd4c7c.example.com');
      expect(args.softwareVersion, '4.7.1+bshockdon (build 1)');
    });
  });

  group('読めないときは null（呼び出し側が /server へ戻す）', () {
    test('クエリなし', () {
      expect(resolveLoginArgs(Uri.parse('/login')), isNull);
    });

    test('host が空', () {
      expect(
        resolveLoginArgs(Uri.parse('/login?host=&backend=misskey')),
        isNull,
      );
    });

    test('backend が無い', () {
      expect(resolveLoginArgs(Uri.parse('/login?host=example.com')), isNull);
    });

    test('知らない backend', () {
      expect(
        resolveLoginArgs(Uri.parse('/login?host=example.com&backend=nostr')),
        isNull,
      );
    });

    /// ⚠⚠ **クエリで運ぶようにしたので、外から値を差し込める**（v1.64 の
    /// リリース前レビュー）。host は `'https://$host/…'` にそのまま入る。
    test('⚠ ホスト名の形でない host は通さない', () {
      for (final bad in [
        'evil.example@good.example',
        'evil.example/path',
        'evil.example?x=1',
        'evil example',
        r'evil.example\good.example',
        'evil.example#frag',
        'good.example:port',
        'a:b:c',
        // 角括弧の中に URL の構造を変える文字を入れても通さない。
        '[2001:db8::1]@evil.example',
        '[evil.example/path]',
      ]) {
        final uri = Uri(
          path: '/login',
          queryParameters: {'host': bad, 'backend': 'mastodon'},
        );
        expect(resolveLoginArgs(uri), isNull, reason: bad);
      }
    });

    test('ホスト名・ポート付き・IP は通す', () {
      for (final good in [
        'mstdn.b-shock.org',
        'st2.misskey.delmulin.com',
        'localhost:3000',
        '192.168.1.10',
        'xn--eckwd4c7c.example.com',
        // ⚠ 手入力の IDN をそのまま probe に通す環境を締め出さない。
        'ドメイン.example',
        // 角括弧の IPv6 表記（リリース PR の Codex P2）。
        '[2001:db8::1]',
        '[::1]:3000',
      ]) {
        final uri = Uri(
          path: '/login',
          queryParameters: {'host': good, 'backend': 'mastodon'},
        );
        expect(resolveLoginArgs(uri)?.host, good, reason: good);
      }
    });
  });

  /// ⚠⚠ **OS から渡された初期ルートで splash / EULA を飛ばさない**（v1.64 の
  /// リリース前レビュー・実機で再現）。`capsicumauth://complete/login?host=…`
  /// でコールドスタートすると、任意ホストのログイン画面が直接開いた。
  test('⚠⚠ GoRouter が初期ルートを OS より優先している', () {
    final code = File('lib/src/router.dart').readAsStringSync();
    expect(
      RegExp(r'overridePlatformDefaultLocation:\s*true').hasMatch(code),
      isTrue,
    );
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      RegExp(
        r'flutter_deeplinking_enabled"\s*android:value="false"',
      ).hasMatch(manifest),
      isTrue,
      reason: 'Android の Flutter deep link を切ってある',
    );
  });

  group('⚠⚠ go_router の挙動（この修正の前提）', () {
    testWidgets('refresh すると extra は落ちるが、クエリは残る', (tester) async {
      final observed = _RouteProbe();
      final refresh = ChangeNotifier();
      addTearDown(refresh.dispose);
      final router = _probeRouter(refresh, observed);
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      router.push(
        loginLocation(
          LoginArgs(host: 'example.com', backendType: BackendType.misskey),
        ),
        // 実物と同じ形（enum を含む）を積んで、落ちる側も同時に測る。
        extra: {'backendType': BackendType.misskey},
      );
      await tester.pumpAndSettle();

      // 1. 走査が空振りしていないこと。push 直後は両方とも読める。
      expect(observed.builds, 1);
      expect(observed.extra, isNotNull, reason: 'push 直後は extra が読める');
      expect(observed.query['host'], 'example.com');

      refresh.notifyListeners();
      await tester.pumpAndSettle();

      // 2. ⚠ 歯。refresh で組み直され、extra だけが消える。
      expect(observed.builds, 2, reason: 'refresh で builder が回る');
      expect(
        observed.extra,
        isNull,
        reason: 'enum を含む extra は JSON にできず、丸ごと null に落ちる',
      );
      expect(
        observed.query['host'],
        'example.com',
        reason: 'クエリは location そのものなので残る',
      );
      expect(
        resolveLoginArgs(Uri.parse(observed.location!))?.backendType,
        BackendType.misskey,
      );
    });

    testWidgets('refresh を跨いでも画面の State は作り直されない', (tester) async {
      // ⚠ **これが崩れると、クエリで運んでも #1057 は直らない。**State ごと
      // 作り直されると、OAuth の完走を待っている `LoginScreen` は `mounted`
      // が false になり、結局 `context.go('/home')` に辿り着けない。
      _StatefulProbeState.instances = 0;
      final refresh = ChangeNotifier();
      addTearDown(refresh.dispose);
      final router = _probeRouter(refresh, _RouteProbe(), stateful: true);
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      router.push(
        loginLocation(
          LoginArgs(host: 'example.com', backendType: BackendType.misskey),
        ),
      );
      await tester.pumpAndSettle();
      expect(_StatefulProbeState.instances, 1);

      refresh.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        _StatefulProbeState.instances,
        1,
        reason: 'refresh は builder を回すだけで、Element は使い回される',
      );
    });

    testWidgets('⚠ push で積んだぶんは top-level redirect の location に出ない', (
      tester,
    ) async {
      // #1057 の直し方を 1 度間違えた原因。`RouteMatchList.push` は
      // `copyWith(matches:)` だけで `uri` を更新しないので、ホームから
      // `/server` → `/login` と積んでも redirect が見る location は `/home`
      // のまま。「今どの画面に居るか」でログイン直後の引き上げを判断できない。
      final seen = <String>[];
      final refresh = ChangeNotifier();
      addTearDown(refresh.dispose);
      final router = GoRouter(
        initialLocation: '/home',
        refreshListenable: refresh,
        redirect: (context, state) {
          seen.add(state.matchedLocation);
          return null;
        },
        routes: [
          GoRoute(path: '/home', builder: (_, _) => const Text('home')),
          GoRoute(path: '/login', builder: (_, _) => const Text('login')),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      router.push('/login?host=example.com&backend=misskey');
      await tester.pumpAndSettle();
      seen.clear();

      refresh.notifyListeners();
      await tester.pumpAndSettle();

      expect(seen, isNotEmpty, reason: 'refresh で redirect が回っている');
      expect(
        seen,
        everyElement('/home'),
        reason: '/login を push してあっても location は /home のまま',
      );
    });
  });
}

class _RouteProbe {
  int builds = 0;
  Object? extra;
  Map<String, String> query = const {};
  String? location;
}

GoRouter _probeRouter(
  ChangeNotifier refresh,
  _RouteProbe probe, {
  bool stateful = false,
}) {
  return GoRouter(
    initialLocation: '/home',
    refreshListenable: refresh,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => const Text('home')),
      GoRoute(
        path: '/login',
        builder: (context, state) {
          probe.builds++;
          probe
            ..extra = state.extra
            ..query = state.uri.queryParameters
            ..location = state.uri.toString();
          return stateful ? const _StatefulProbe() : const Text('login');
        },
      ),
    ],
  );
}

class _StatefulProbe extends StatefulWidget {
  const _StatefulProbe();

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  static int instances = 0;

  @override
  void initState() {
    super.initState();
    instances++;
  }

  @override
  Widget build(BuildContext context) => const Text('login');
}
