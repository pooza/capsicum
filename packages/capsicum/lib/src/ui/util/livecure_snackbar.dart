import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';
import '../../provider/timeline_provider.dart';

/// Shows a SnackBar when the user's just-posted content contains #実況 while
/// hideLivecureProvider is on, so they don't think their post failed (#433).
///
/// 判定対象は postStatus が返した Post (= モロヘイヤが handler で #実況 を
/// 追記した後の状態) であり、ユーザー入力本文ではない。これでチャンネル
/// 接尾辞・モロヘイヤ自動付与・ユーザーの明示入力のいずれの経路でも一貫
/// して動く。
///
/// SnackBar のアクションは host widget が pop された後に発火しうるため、
/// 表示前に notifier 参照を捕捉する (#546)。
void maybeShowHideLivecureSnackBar(
  BuildContext context,
  WidgetRef ref,
  Post? post,
) {
  if (post == null) return;
  if (!ref.read(hideLivecureProvider)) return;
  if (!hasLivecureTag(post)) return;

  final notifier = ref.read(hideLivecureProvider.notifier);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('投稿しました（現在 #実況 を非表示中のため、タイムラインには表示されません）'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: '表示する',
        onPressed: () => notifier.setHidden(false),
      ),
    ),
  );
}
