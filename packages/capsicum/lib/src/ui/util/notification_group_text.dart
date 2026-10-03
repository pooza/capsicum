import 'package:capsicum_core/capsicum_core.dart';

/// 束ねた通知の見出しの「…が〜しました」の部分 (#1048)。
///
/// 既存の形（`<表示名> が<ラベル>`）を保ったまま、2 件以上のときだけ人数を足す。
/// **ラベルは種別ごとの文字列**（「お気に入り」「ブースト」…）で
/// `notificationTypeDisplay` が持つ。
///
/// ⚠ **人数は通知の件数で、人の数ではない。**同じ相手のフォロー → 解除 →
/// 再フォローは 3 件の通知として数えられる（Mastodon の `notifications_count`）。
/// 本家 WebUI の「X and N others」も同じ数え方なので合わせてある。
String notificationActorSuffix({
  required int groupCount,
  required String label,
}) {
  if (groupCount <= 1) return ' が$label';
  return ' ほか${groupCount - 1}人が$label';
}

/// 相手が分からない通知（[Notification.user] が null）で人数だけ出す形 (#1048)。
///
/// ⚠ 代表アカウントを引き当てられなかったグループで使う。ここで
/// `notificationActorSuffix` を使うと先頭が「 ほか…」で始まってしまう。
String notificationActorlessLabel({
  required int groupCount,
  required String label,
}) => groupCount <= 1 ? label : '$groupCount人が$label';
