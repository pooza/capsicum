import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../url_helper.dart';

/// 投稿本文・お知らせ等に貼られた URL タップの共通ハンドラ (#820)。
///
/// fediverse の投稿 / アカウント URL は、アクティブなアカウント（ログイン中
/// サーバー）の adapter で resolve し、アプリ内のスレッド（`/post`）/ プロフィール
/// （`/profile`）へ遷移させる。それ以外（外部サイト・resolve 失敗）は
/// [launchInPreferredApp] に流し、YouTube / Apple Music 等は専用アプリ、それ以外は
/// ブラウザで開く（#755）。
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

  // 自ホストの Misskey Play はネイティブ画面で開く (#830)。他ホストは当該
  // サーバーの adapter が無く getFlashById できないので、判定で弾いて下の
  // ブラウザ経路にフォールバックさせる。
  final playId = _selfHostPlayId(uri, adapter);
  if (playId != null) {
    context.push('/play', extra: {'flashId': playId});
    return;
  }

  if (adapter is SearchSupport && looksLikeFediverseUrl(uri)) {
    // resolve の await 中は無反応でブラウザが開くまで dead-tap に見えるため、
    // 軽量な進捗表示を出す（#838）。ナビ / ブラウザに移る前に必ず消す。
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('リンクを開いています…'),
        duration: Duration(seconds: 4),
      ),
    );
    try {
      final results = await (adapter as SearchSupport).search(url);
      messenger.hideCurrentSnackBar();
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
      messenger.hideCurrentSnackBar();
    }
  }

  if (context.mounted) {
    // fediverse 投稿 / アカウントでない外部 URL は、対応する専用アプリがあれば
    // そちらで開く（YouTube / Apple Music / Spotify / Amazon 等・モバイルのみ）。
    // アプリ未インストール時は browserMode でブラウザにフォールバックする (#755)。
    // 開けるアプリ / ブラウザが無いと launchUrl は false を返すか throw するため、
    // 握りつぶさず「開けなかった」ことをユーザーに見せる（無反応の dead-tap 回避）。
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchInPreferredApp(uri, browserMode: browserMode);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      messenger.showSnackBar(const SnackBar(content: Text('リンクを開けませんでした')));
    }
  }
}

/// URL が fediverse の投稿 / アカウント URL らしいか。無条件 resolve を避ける
/// ためのガード (#820)。false negative はブラウザに落ちるだけなので許容しつつ、
/// 非 fedi URL での無駄なホーム鯖 round-trip を減らすため判定を絞り込む (#838)。
///
/// - Mastodon / Misskey アカウント・投稿: 先頭が `@user`（`/@user`・`/@user/123`）
/// - Misskey ノート: `/notes/<id>`（`<id>` が Misskey の英数 ID らしい形のときのみ。
///   `example.com/notes/x` のような他サイトの誤検知を弾く）
/// - Mastodon の ActivityPub 形式ステータス: `/users/<name>/statuses/<id>`
///   （`users` と `statuses` の両方を要求。bare な `/users/foo`＝github 等は弾く）
/// URL が「アクティブアカウントと同じホストの Misskey Play」なら、その Play
/// ID を返す（`https://<host>/play/<id>`）。ネイティブの `/play` 画面は現在の
/// adapter で `getFlashById` するため、自ホストのときだけネイティブで開ける。
/// 他ホスト・Play でない URL は null（呼び出し側でブラウザ等にフォールバック）。
String? _selfHostPlayId(Uri uri, Object? adapter) {
  if (adapter is! DecentralizedBackendAdapter || adapter is! FlashSupport) {
    return null;
  }
  return misskeyPlayIdOnHost(uri, adapter.host);
}

/// `https://<host>/play/<id>` で host が [selfHost] と一致するとき Play ID を
/// 返す。他ホスト・Play でない URL・selfHost が null なら null。ホスト一致を
/// 要求するのは、ネイティブ画面が現在の adapter で解決するため（#830）。
String? misskeyPlayIdOnHost(Uri uri, String? selfHost) {
  if (selfHost == null || uri.host != selfHost) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length >= 2 && segments.first == 'play') return segments[1];
  return null;
}

bool looksLikeFediverseUrl(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return false;
  if (segments.first.startsWith('@')) return true;
  if (segments.first == 'notes' &&
      segments.length >= 2 &&
      _looksLikeObjectId(segments[1])) {
    return true;
  }
  if (segments.contains('users') && segments.contains('statuses')) return true;
  return false;
}

/// Misskey / Mastodon のオブジェクト ID らしい形（英数 6 文字以上）。短い任意
/// セグメント（`notes/x` 等）を fediverse ノートと誤判定しないためのガード。
bool _looksLikeObjectId(String s) => RegExp(r'^[0-9a-zA-Z]{6,}$').hasMatch(s);
