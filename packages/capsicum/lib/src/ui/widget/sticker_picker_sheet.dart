import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import 'emoji_picker.dart';
import 'picker_sheet_account_context.dart';
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

  // シート builder の遅延実行に備えた退避（#739 の詳細は
  // [PickerSheetAccountContext]）。
  final picker = PickerSheetAccountContext.capture(
    context: context,
    account: account,
  );

  return showModalBottomSheet<CustomEmoji>(
    context: context,
    isScrollControlled: true,
    // builder 自身の context を使う。外側の context を握ると、呼び出し元が
    // 再描画されて context が外れたとき MediaQuery._of が null check で fatal
    // になる (#683 / Sentry CAPSICUM-2T)。
    builder: (sheetContext) => ResizablePickerSheet(
      screenHeight: picker.screenHeight,
      heightProvider: stickerPickerHeightProvider,
      child: EmojiPicker(
        adapter: picker.backend,
        host: picker.host,
        mulukhiya: picker.mulukhiya,
        accessToken: picker.accessToken,
        onCustomEmojiSelected: (emoji) => Navigator.of(sheetContext).pop(emoji),
      ),
    ),
  );
}
