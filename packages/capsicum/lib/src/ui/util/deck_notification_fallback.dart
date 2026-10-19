import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/deck_provider.dart';
import '../../provider/timeline_provider.dart';

/// `ref.read` / `container.read` のどちらでも渡せる形。
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// デッキ宛てに立てた通知のタップ（[pendingDeckNotificationsProvider]）を、
/// **デッキが受けなかったとき**にタブ表示の通知タブへ振り替える (#1304)。
///
/// 振り替えるのは、デッキが現れる見込みで立てたのに外れた回:
///
/// - 起動時に「デッキで始めるか」の判定が見送った（共有・ディープリンクから
///   起動した等）。呼ぶのは `HomeScreen`
/// - デッキを閉じた直後の 1 フレームにタップした（数えている開いたデッキの数は
///   フレームの後で減るので、閉じかけのデッキ宛てに立ってしまう）。呼ぶのは
///   通知の経路（`main.dart`）で、数フレーム後に印が残っていたとき
///
/// ⚠⚠ **放っておくと、後で手でデッキを開いたときに頼んでいない通知カラムが
/// 足される**（印が宙に浮いたまま残る）。
///
/// やることはタブ表示の通知の経路と同じ: 宛先のアカウントへ切り替え、通知タブを
/// 開く印（[pendingInitialTabProvider]）を立てる。⚠ 画面の遷移はしない（呼ぶ側が
/// 決める）。振り替えたら true。
bool releasePendingDeckNotification(ProviderReader read) {
  final target = read(pendingDeckNotificationsProvider);
  if (target == null) return false;
  read(pendingDeckNotificationsProvider.notifier).state = null;

  final state = read(accountManagerProvider);
  final account = state.accounts.where((a) => a.key == target).firstOrNull;
  if (account != null && state.current?.key != target) {
    read(accountManagerProvider.notifier).switchAccount(account);
  }
  read(pendingInitialTabProvider.notifier).state = const NotificationsTab();
  return true;
}
