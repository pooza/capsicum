import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/antenna_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../util/antenna_text.dart';
import '../util/op_error.dart';
import '../widget/antenna_actions_sheet.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

/// 行の 2 行目に出す、条件の手がかり (#1052)。キーワードが無ければ null。
///
/// ⚠ 「かつ」は空白、「または」は「 / 」で見せる（入力欄の改行は 1 行に収まら
/// ないため）。
@visibleForTesting
String? antennaKeywordsSummary(Antenna antenna) {
  final keywords = antenna.conditions?.keywords ?? const [];
  if (keywords.isEmpty) return null;
  return antennaKeywordsToText(keywords).replaceAll('\n', ' / ');
}

/// アンテナを管理する画面 (#1052)。
///
/// ドロワーのクイックチューザ（`showAntennaList`）の奥に置く。型はチャンネル
/// （#1051・`channel_management_screen.dart`）と同じ。
class AntennaManagementScreen extends ConsumerWidget {
  const AntennaManagementScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final saved = await context.push<bool>('/antennas/edit');
    if (saved == true) ref.invalidate(antennasProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final antennas = ref.watch(antennasProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('アンテナ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新規作成',
            onPressed: () => _create(context, ref),
          ),
        ],
      ),
      body: BottomSafeArea(
        child: antennas.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => RetryErrorView(
            message: isOAuthScopeError(e)
                ? oauthScopeErrorMessage
                : '読み込みに失敗しました\n${summarizeOpError(e)}',
            isRetrying: antennas.isLoading,
            onRetry: () => ref.invalidate(antennasProvider),
          ),
          data: (list) {
            if (list.isEmpty) {
              return const Center(child: Text('アンテナはありません\n右上の ＋ から作れます'));
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final antenna = list[index];
                final summary = antennaKeywordsSummary(antenna);
                return ListTile(
                  leading: const Icon(Icons.settings_input_antenna),
                  title: Text(
                    antenna.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: summary == null
                      ? null
                      : Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  onTap: () => context.push(
                    '/antenna/${antenna.id}',
                    extra: antenna.name,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.more_horiz),
                    tooltip: 'アンテナの操作',
                    onPressed: () => showAntennaActions(context, ref, antenna),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
