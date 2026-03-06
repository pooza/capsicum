import 'package:capsicum_core/capsicum_core.dart';

import 'mastodon/adapter.dart';
import 'misskey/adapter.dart';

enum BackendType {
  mastodon(MastodonAdapter.create, 'Mastodon'),
  misskey(MisskeyAdapter.create, 'Misskey');

  final Future<DecentralizedBackendAdapter> Function(String host) createAdapter;
  final String displayName;
  const BackendType(this.createAdapter, this.displayName);
}
