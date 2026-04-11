import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

/// UI representation of a [PostScope] — varies between Mastodon and Misskey.
class PostScopeDisplay {
  final String label;
  final IconData icon;

  const PostScopeDisplay({required this.label, required this.icon});
}

/// Whether the given adapter uses Misskey-style naming/icons for scopes.
bool isMisskeyAdapter(BackendAdapter? adapter) => adapter is ReactionSupport;

const _mastodonScopes = {
  PostScope.public: PostScopeDisplay(label: '公開', icon: Icons.public),
  PostScope.unlisted: PostScopeDisplay(
    label: 'ひかえめな公開',
    icon: Icons.nightlight_outlined,
  ),
  PostScope.followersOnly: PostScopeDisplay(
    label: 'フォロワー',
    icon: Icons.lock_outline,
  ),
  PostScope.direct: PostScopeDisplay(
    label: '非公開の返信',
    icon: Icons.alternate_email,
  ),
};

const _misskeyScopes = {
  PostScope.public: PostScopeDisplay(label: 'パブリック', icon: Icons.public),
  PostScope.unlisted: PostScopeDisplay(label: 'ホーム', icon: Icons.home_outlined),
  PostScope.followersOnly: PostScopeDisplay(
    label: 'フォロワー',
    icon: Icons.lock_outline,
  ),
  PostScope.direct: PostScopeDisplay(label: '指名', icon: Icons.mail_outline),
};

/// Returns the display info for [scope] under the current [adapter]'s conventions.
PostScopeDisplay postScopeDisplay(PostScope scope, BackendAdapter? adapter) {
  final table = isMisskeyAdapter(adapter) ? _misskeyScopes : _mastodonScopes;
  return table[scope]!;
}

String postScopeLabel(PostScope scope, BackendAdapter? adapter) =>
    postScopeDisplay(scope, adapter).label;

IconData postScopeIcon(PostScope scope, BackendAdapter? adapter) =>
    postScopeDisplay(scope, adapter).icon;

/// Scopes selectable when boosting/renoting a post of the given [originalScope].
///
/// Only `public` originals have multiple choices ({public, unlisted}). Other
/// scopes return an empty list, meaning "no choice — use the default boost".
List<PostScope> boostableScopes(PostScope originalScope) {
  if (originalScope == PostScope.public) {
    return const [PostScope.public, PostScope.unlisted];
  }
  return const [];
}
