import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import 'emoji_picker.dart';
import 'resizable_picker_sheet.dart';

/// 添付画像に重ねるスタンプ（カスタム絵文字）を選ぶボトムシート (#883)。
///
/// リアクションピッカー (#907) と同じ [ResizablePickerSheet] に乗せ、高さは
/// [stickerPickerHeightProvider] に別途覚える。素材の供給元をカスタム絵文字に
/// 限っているのは #883 の初期スコープどおりで、端末内画像 / 内蔵セットは対象外。
///
/// 選択された絵文字を返す。シートは選択時点で閉じるので、呼び出し側で pop する
/// 必要はない。キャンセル時は null。
Future<CustomEmoji?> showStickerPickerSheet({
  required BuildContext context,
  required WidgetRef ref,
}) async {
  final account = ref.read(currentAccountProvider);
  final adapter = account?.adapter;
  if (account == null || adapter is! CustomEmojiSupport) return null;

  // シート builder は遅延実行される。実行時点で currentAccountProvider が
  // 入れ替わっていても安全なよう、ここで確定した非 null 値をローカルへ退避し、
  // closure 内で `!` / `as` を再評価しない (#739 / Sentry CAPSICUM-32)。
  final backend = adapter as BackendAdapter;
  final host = account.key.host;
  final mulukhiya = account.mulukhiya;
  final accessToken = account.userSecret.accessToken;
  // 画面高は親 context から取る（sheet 表示後もキーボード開閉で不変）。
  final screenHeight = MediaQuery.of(context).size.height;

  return showModalBottomSheet<CustomEmoji>(
    context: context,
    isScrollControlled: true,
    // builder 自身の context を使う。外側の context を握ると、呼び出し元が
    // 再描画されて context が外れたとき MediaQuery._of が null check で fatal
    // になる (#683 / Sentry CAPSICUM-2T)。
    builder: (sheetContext) => ResizablePickerSheet(
      screenHeight: screenHeight,
      heightProvider: stickerPickerHeightProvider,
      child: EmojiPicker(
        adapter: backend,
        host: host,
        mulukhiya: mulukhiya,
        accessToken: accessToken,
        onCustomEmojiSelected: (emoji) => Navigator.of(sheetContext).pop(emoji),
      ),
    ),
  );
}
