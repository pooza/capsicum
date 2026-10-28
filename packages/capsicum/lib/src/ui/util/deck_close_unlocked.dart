import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/deck_provider.dart';
import '../../provider/preferences_provider.dart';

// ロックしていないカラムをまとめて閉じる (#1307・2026-10-27 pooza 判断)。
//
// ロックを「常設のカラム」の印として使い、カラムから開いて右へ溜まっていく
// 使い捨てのカラム（スレッド・プロフィール・検索など）を 1 回で片付ける。
//
// - 入口はカラム編集のシートと、メニューバーの「表示 > カラム」
//   （Cmd / Ctrl + Shift + W）
// - ロック中が 1 本以上、かつロックしていないカラムが 1 本以上のときだけ
//   押せる。条件を満たさないときは隠さず、押せなくする
// - 確認も「元に戻す」も挟まない。閉じるのは使い捨てのカラムだけで、
//   失っても開き直せる
// - 閉じたあとのフォーカスは deckFocusAfterClosingUnlocked

/// 閉じる対象のカラムの id。押せないとき（ロック中が無い・ロックしていない
/// カラムが無い）は空。
List<String> unlockedDeckColumnIdsToClose(
  List<String> columnIds,
  Set<String> locked,
) {
  if (!columnIds.any(locked.contains)) return const [];
  return [
    for (final id in columnIds)
      if (!locked.contains(id)) id,
  ];
}

/// 閉じたあとにフォーカスするカラム。押せないときは null。
///
/// フォーカス中のカラムがロック中ならそのまま。そうでなければ、左にある
/// いちばん近いロック中のカラム（無ければ右にあるいちばん近いもの）。
/// フォーカスが無い・列に居ないときは、先頭のロック中のカラム。
String? deckFocusAfterClosingUnlocked(
  List<String> columnIds,
  Set<String> locked,
  String? focusedId,
) {
  if (unlockedDeckColumnIdsToClose(columnIds, locked).isEmpty) return null;
  final index = focusedId == null ? -1 : columnIds.indexOf(focusedId);
  if (index < 0) return columnIds.firstWhere(locked.contains);
  if (locked.contains(focusedId)) return focusedId;
  for (var i = index - 1; i >= 0; i--) {
    if (locked.contains(columnIds[i])) return columnIds[i];
  }
  for (var i = index + 1; i < columnIds.length; i++) {
    if (locked.contains(columnIds[i])) return columnIds[i];
  }
  return null;
}

/// いまの列で押せるか。
bool canCloseUnlockedDeckColumns(WidgetRef ref) => unlockedDeckColumnIdsToClose(
  [for (final c in ref.watch(deckColumnsProvider)) c.id],
  ref.watch(deckLockedColumnsProvider),
).isNotEmpty;

/// ロックしていないカラムを閉じる。押せないときは何もしない。
///
/// ⚠ **先にフォーカスを移してから外す**（#1172 の「フォーカスの宛先が無い瞬間を
/// 作らない」）。移す先はロック中のカラムなので、外したあとの列にも居る。
/// 外したあとは、そのカラムまで横に送る（列が詰まって、見えている位置が
/// ずれるため）。
Future<void> closeUnlockedDeckColumns(WidgetRef ref) async {
  final columnIds = [for (final c in ref.read(deckColumnsProvider)) c.id];
  final locked = ref.read(deckLockedColumnsProvider);
  final toClose = unlockedDeckColumnIdsToClose(columnIds, locked);
  if (toClose.isEmpty) return;
  final focus = deckFocusAfterClosingUnlocked(
    columnIds,
    locked,
    ref.read(deckFocusProvider).columnId,
  );
  // ⚠ 送る操作は先に取っておく。シートから呼ぶと、フレームの後にはシートが
  // 閉じていて `ref` が使えないことがある。
  final actions = ref.read(deckMenuActionsProvider);
  if (focus != null) ref.read(deckFocusProvider.notifier).focus(focus);
  await ref.read(deckColumnsProvider.notifier).removeAll(toClose.toSet());
  if (focus == null || actions == null) return;
  // ⚠ 外した直後のフレームではまだ列が組み直されていない。組み上がってから送る。
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => actions.revealAndFocus(focus),
  );
}
