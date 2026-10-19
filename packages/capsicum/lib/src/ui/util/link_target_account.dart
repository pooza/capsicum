import 'package:flutter/material.dart';

import '../../model/account_key.dart';
import '../widget/server_badge.dart';

/// サーバー保管型の連携（Annict / Spotify）で、**どのアカウントを連携するか**の
/// 表記 (#1312)。「美食丼の @pooza@mstdn.b-shock.org」。
///
/// ⚠⚠ 連携はサーバー側（モロヘイヤ）に保管され、以後そのサーバーが投稿を続ける。
/// 2026-10-19 に、タブ表示が別のサーバーのアカウントへ移っていたのに気付かず
/// 連携し、2 つのサーバーから同じ感想が投稿されるようになった。確認のダイアログに
/// 出していなかったので、取り違えに気付く場所が無かった。
///
/// サーバーの名前がまだ取れていない（ホスト名と同じ）ときは、ハンドルだけにする。
String linkTargetAccountLabel(AccountKey key) {
  final handle = '@${key.username}@${key.host}';
  final name = serverDisplayName(key.host);
  return name == key.host ? handle : '$name の $handle';
}

/// 連携の確認ダイアログの本文。先頭に対象のアカウントを太字で出す。
Widget linkTargetDialogContent(
  AccountKey key,
  String body, {
  String heading = '連携するアカウント',
}) => Text.rich(
  TextSpan(
    children: [
      TextSpan(text: '$heading\n'),
      TextSpan(
        text: linkTargetAccountLabel(key),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      TextSpan(text: '\n\n$body'),
    ],
  ),
);
