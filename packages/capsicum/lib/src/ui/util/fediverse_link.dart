import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../url_helper.dart';

/// 投稿本文・お知らせ等に貼られた URL タップの共通ハンドラ (#820)。
///
/// fediverse の投稿 / アカウント URL は、アクティブなアカウント（ログイン中
/// サーバー）の adapter で resolve し、アプリ内のスレッド（`/post`）/ プロフィール
/// （`/profile`）へ遷移させる。それ以外（外部サイト・resolve 失敗）は従来どおり
/// ブラウザで開く。
///
/// resolve は search API に URL を投げるため、無条件には行わない。fediverse の
/// 投稿 / アカウント URL のパターンに一致するときだけ試行し、Google Form 等の
/// 外部リンクは判定で弾いてそのままブラウザに送る。resolve 先の Post / User の
/// ID はアクティブサーバーローカルで、リモート投稿は「そのサーバーから見た
/// スレッド」になる（返信が欠けうる）点は仕様。
Future<void> openFediverseLink(
  BuildContext context,
  WidgetRef ref,
  String url, {
  LaunchMode browserMode = LaunchMode.platformDefault,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;

  final adapter = ref.read(currentAdapterProvider);
  if (adapter is SearchSupport && looksLikeFediverseUrl(uri)) {
    try {
      final results = await (adapter as SearchSupport).search(url);
      if (!context.mounted) return;
      if (results.posts.isNotEmpty) {
        context.push('/post', extra: results.posts.first);
        return;
      }
      if (results.users.isNotEmpty) {
        context.push('/profile', extra: results.users.first);
        return;
      }
    } catch (_) {
      // resolve 失敗（連合越し不達・非投稿 URL 等）はブラウザへフォールバック。
    }
  }

  if (context.mounted) {
    await launchUrlSafely(uri, mode: browserMode);
  }
}

/// URL が fediverse の投稿 / アカウント URL らしいか。無条件 resolve を避ける
/// ためのガード (#820)。判定は緩め（false negative でブラウザに落ちるだけ）だが、
/// 素の外部サイト（`example.com/form` 等）は弾く。
///
/// - Mastodon / Misskey アカウント・投稿: 先頭が `@user`（`/@user`・`/@user/123`）
/// - Misskey ノート: `/notes/xxx`
/// - Mastodon ユーザー / ステータス: `/users/...`・`.../statuses/...`
bool looksLikeFediverseUrl(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return false;
  if (segments.first.startsWith('@')) return true;
  if (segments.contains('notes') ||
      segments.contains('users') ||
      segments.contains('statuses')) {
    return true;
  }
  return false;
}
