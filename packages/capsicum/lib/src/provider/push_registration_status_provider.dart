import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/push_registration_status.dart';

/// 全アカウントのプッシュ登録状態のライブビュー。
///
/// 初期値は [PushRegistrationStatusStore.snapshots]（既に走った登録の最後の
/// 状態）、以降は [PushRegistrationStatusStore.changes] から差分を受ける。
final pushRegistrationStatusProvider =
    StreamProvider<Map<String, PushRegistrationSnapshot>>((ref) async* {
      final store = PushRegistrationStatusStore.instance;
      yield store.snapshots;
      yield* store.changes;
    });
