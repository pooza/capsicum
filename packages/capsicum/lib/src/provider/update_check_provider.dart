import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/update_checker.dart';
import 'preferences_provider.dart';

/// 直配ビルドかつ設定 ON のときだけ GitHub Release を 1 回問い合わせ、
/// 新版があれば [UpdateInfo] を返す (#641)。`FutureProvider` なので結果は
/// セッション中キャッシュされ、起動ごとに 1 回だけ走る。
///
/// ストアビルドや「更新検知 OFF」設定では `null` を即返し、ネットワーク
/// 通信も行わない。
final updateCheckProvider = FutureProvider<UpdateInfo?>((ref) async {
  if (!kIsDirectChannelBuild) return null;
  if (!ref.watch(updateCheckEnabledProvider)) return null;
  return UpdateChecker.check();
});
