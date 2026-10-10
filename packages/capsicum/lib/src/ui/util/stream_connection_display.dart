import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

/// ライブ更新の接続状態の見せ方（色とラベル）の正本 (#1235)。
///
/// ⚠ **タブ UI とデッキのカラムへ別々に写されていて、既に食い違っていた**
/// （`exhausted` の色がデッキは `Colors.red`・ホームは `colorScheme.error`、
/// ツールチップの前置きもデッキには無かった）。状態を足す・文面を直すときは
/// ここだけを直す。
({Color color, String label}) streamConnectionDisplay(
  BuildContext context,
  StreamConnectionState state,
) => switch (state) {
  StreamConnectionState.live => (color: Colors.green, label: 'ライブ更新中'),
  StreamConnectionState.connecting => (color: Colors.amber, label: '接続中…'),
  StreamConnectionState.disconnected => (
    color: Colors.orange,
    label: '切断 — 再接続中',
  ),
  // #784 で give-up しなくなったため「停止」ではなく「不安定・再試行中」。
  StreamConnectionState.exhausted => (
    color: Theme.of(context).colorScheme.error,
    label: '接続が不安定 — 再試行中',
  ),
  // ユーザーが設定でライブ更新を OFF にしている (#854)。エラーではないので
  // 灰色で「オフ」と正直に出す。pull-to-refresh / タブ再選択で更新できる。
  StreamConnectionState.disabled => (color: Colors.grey, label: 'ライブ更新オフ'),
};

/// ツールチップの文面。⚠ **何の状態かを前置きする**（点だけでは「ライブ更新」
/// の話だと分からない）。
String streamConnectionTooltip(String label) => 'ライブ更新: $label';
