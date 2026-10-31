import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';

/// デッキの画面全体に敷く背景画像 (#1174・`docs/deck-ui-decisions.md` 決定済み
/// 事項 12)。画像はデッキ専用に 1 枚設定する（カラムごとに違うアカウントが並ぶ
/// ので、どれかのアカウントの画像を借りない）。
///
/// カラムの中身の多くは `embedded` でも `Scaffold` を返し、既定で不透明に塗る。
/// 20 種類前後のタブを個別に直さず、ここで `scaffoldBackgroundColor` を透明に
/// 差し替えて透かす。⚠ 画像が無いときは差し替えない（見た目を変えない）。
class DeckBackground extends ConsumerWidget {
  const DeckBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(backgroundImageProvider(deckBackgroundStorageKey));
    final opacity = ref.watch(
      backgroundOpacityProvider(deckBackgroundStorageKey),
    );
    final theme = Theme.of(context);
    // ⚠ 画像の有無で木の形を変えない。変えるとカラムの State がすべて作り直される。
    return DecoratedBox(
      decoration: path == null
          ? const BoxDecoration()
          : BoxDecoration(
              image: DecorationImage(
                image: FileImage(File(path)),
                fit: BoxFit.cover,
                opacity: opacity,
                // ⚠ 画像が読めなくても、カラムの表示は止めない。
                onError: (_, _) {},
              ),
            ),
      child: Theme(
        data: path == null
            ? theme
            : theme.copyWith(scaffoldBackgroundColor: Colors.transparent),
        child: child,
      ),
    );
  }
}
