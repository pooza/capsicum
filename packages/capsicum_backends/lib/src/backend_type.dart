import 'package:capsicum_core/capsicum_core.dart';

import 'mastodon/adapter.dart';
import 'misskey/adapter.dart';

enum BackendType {
  mastodon(MastodonAdapter.create),
  misskey(MisskeyAdapter.create);

  final Future<DecentralizedBackendAdapter> Function(String host) createAdapter;
  const BackendType(this.createAdapter);
}
