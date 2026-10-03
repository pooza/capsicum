import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

import 'user_avatar.dart';

/// 束ねた通知の代表アカウントを重ねて並べる (#1048)。
///
/// ⚠ **横に並べない。**通知行の見出しは「アイコン + 名前 + 相対時刻」で既に
/// 埋まっていて、デッキのカラムは 320px で運用される（`docs/deck-ui-plan.md`）。
/// 4 人を素の `Row` で並べると 96px 取られて名前が消えるので、[overlap] だけ
/// ずらして重ねる（4 人で 60px）。
///
/// ⚠ **[maxCount] を超えたぶんは出さない。**「+N」を足すと、人数は見出しの文字列
/// （`notificationActorSuffix`）と二重に出ることになる。
class StackedAvatars extends StatelessWidget {
  const StackedAvatars({
    super.key,
    required this.users,
    this.size = 24,
    this.maxCount = 4,
    this.overlap = 12,
    this.onTapFirst,
  });

  final List<User> users;
  final double size;
  final int maxCount;

  /// 1 人ぶんの実効幅。[size] より小さいほど重なる。
  final double overlap;

  /// 先頭のアイコンを押したときの動作（プロフィールを開く）。
  ///
  /// ⚠ 2 人目以降には付けない。**重なっているので狙って押せない**（押せそうに
  /// 見えて別の人が開くのが最悪）。
  final VoidCallback? onTapFirst;

  @override
  Widget build(BuildContext context) {
    final shown = users.take(maxCount).toList();
    if (shown.isEmpty) return SizedBox(width: size, height: size);
    final width = size + overlap * (shown.length - 1);
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      height: size,
      child: Stack(
        children: [
          // ⚠ 後ろの人を先に描く（先頭が一番手前に来る）。逆にすると、
          // タップできる先頭のアイコンが他人の下に隠れる。
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: overlap * i,
              child: Container(
                decoration: BoxDecoration(
                  // 重なりの境界を出す。背景画像を敷いていても人数が数えられる。
                  border: Border.all(color: theme.colorScheme.surface),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: i == 0 && onTapFirst != null
                    ? GestureDetector(
                        onTap: onTapFirst,
                        child: UserAvatar(
                          user: shown[i],
                          size: size - 2,
                          borderRadius: 3,
                        ),
                      )
                    : UserAvatar(
                        user: shown[i],
                        size: size - 2,
                        borderRadius: 3,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
