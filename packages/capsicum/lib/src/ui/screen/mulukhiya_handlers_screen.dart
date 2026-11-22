import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

/// 利用者が切り替えられるモロヘイヤのハンドラーの一覧 (#1398)。
///
/// 切り替える口（`handler/list` / `handler/config`・モロヘイヤ 5.47.0）を持つ
/// サーバー（[MulukhiyaService.userHandlerConfigEnabled]）でだけ中身が入る。
final mulukhiyaUserHandlersProvider =
    FutureProvider.autoDispose<List<MulukhiyaUserHandler>>((ref) async {
      final account = ref.watch(currentAccountProvider);
      final mulukhiya = account?.mulukhiya;
      if (account == null ||
          mulukhiya == null ||
          !mulukhiya.userHandlerConfigEnabled) {
        return [];
      }
      try {
        return await mulukhiya.getUserHandlers(
          accessToken: account.userSecret.accessToken,
        );
      } catch (e, st) {
        reportOpFailure(
          tagKey: 'handler.op',
          operation: 'load_list',
          error: e,
          stackTrace: st,
          account: account,
        );
        rethrow;
      }
    }, dependencies: [currentAccountProvider]);

/// 投稿の自動処理（モロヘイヤのハンドラー）を、自分の投稿についてオン / オフ
/// する画面 (#1398)。
///
/// - トグルスイッチの一覧。`toggleable: false` のものはスイッチを無効にして並べる
/// - 切り替えは 1 件ずつ送る。**送っている間は、ほかのスイッチも押せない**
///   （モロヘイヤは利用者の設定を「読んで足して書く」で保存するので、別々の
///   項目でも並べて送ると片方が消える・リリース前レビュー 2026-11-22）
/// - 失敗したら、送る前の値（直前に成功した値）へ戻して知らせる
/// - サーバー全体の設定は変えない（利用者の設定だけ）
class MulukhiyaHandlersScreen extends ConsumerStatefulWidget {
  const MulukhiyaHandlersScreen({super.key});

  @override
  ConsumerState<MulukhiyaHandlersScreen> createState() =>
      _MulukhiyaHandlersScreenState();
}

class _MulukhiyaHandlersScreenState
    extends ConsumerState<MulukhiyaHandlersScreen> {
  /// 送っている途中のハンドラー。⚠ 1 件でもあれば、全部のスイッチを止める。
  final _busy = <String>{};

  /// 切り替えたあとの値（一覧を取り直すまで画面に反映する）。
  final _overrides = <String, bool>{};

  Future<void> _toggle(MulukhiyaUserHandler handler, bool enabled) async {
    final account = ref.read(currentAccountProvider);
    final mulukhiya = account?.mulukhiya;
    if (account == null || mulukhiya == null || _busy.isNotEmpty) return;
    // ⚠ 戻す先は一覧を取った時点の値ではなく、いま画面に出ている値（直前に
    // 成功した切り替えを含む）。
    final before = _overrides[handler.name] ?? handler.disabled;
    setState(() {
      _busy.add(handler.name);
      _overrides[handler.name] = !enabled;
    });
    try {
      final disabled = await mulukhiya.setUserHandlerDisabled(
        accessToken: account.userSecret.accessToken,
        handler: handler.name,
        disabled: !enabled,
      );
      if (mounted) setState(() => _overrides[handler.name] = disabled);
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'handler.op',
        operation: 'toggle',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (!mounted) return;
      // 送る前の値へ戻す。
      setState(() => _overrides[handler.name] = before);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('切り替えられませんでした')));
    } finally {
      if (mounted) setState(() => _busy.remove(handler.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final handlersAsync = ref.watch(mulukhiyaUserHandlersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('投稿の自動処理')),
      body: BottomSafeArea(
        child: handlersAsync.when(
          data: (handlers) {
            if (handlers.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('切り替えられる処理はありません。', textAlign: TextAlign.center),
                ),
              );
            }
            return ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'このアカウントの投稿に、サーバーが自動で行う処理です。'
                    'オフにした処理は、あなたの投稿にだけ効かなくなります。',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                for (final handler in handlers)
                  _HandlerTile(
                    handler: handler,
                    disabled: _overrides[handler.name] ?? handler.disabled,
                    busy: _busy.isNotEmpty,
                    onChanged: (enabled) => _toggle(handler, enabled),
                  ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => RetryErrorView(
            message: '一覧を読み込めませんでした',
            onRetry: () {
              _overrides.clear();
              ref.invalidate(mulukhiyaUserHandlersProvider);
            },
          ),
        ),
      ),
    );
  }
}

class _HandlerTile extends StatelessWidget {
  const _HandlerTile({
    required this.handler,
    required this.disabled,
    required this.busy,
    required this.onChanged,
  });

  final MulukhiyaUserHandler handler;
  final bool disabled;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final lines = [
      ?handler.description,
      // ⚠ 切り替えられないものは、隠さず理由を添えて無効にする。
      if (!handler.toggleable) 'このサーバーでは切り替えられません',
    ];
    return SwitchListTile(
      key: ValueKey('mulukhiya-handler-${handler.name}'),
      title: Text(handler.label ?? handler.name),
      subtitle: lines.isEmpty ? null : Text(lines.join('\n')),
      value: !disabled,
      onChanged: handler.toggleable && !busy ? onChanged : null,
    );
  }
}
