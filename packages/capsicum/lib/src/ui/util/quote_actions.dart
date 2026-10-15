import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

import 'compose_settings_display.dart';

/// 引用された側・引用を許す側の道具 (#1213)。Mastodon 4.5 以降の引用機能のうち、
/// 「自分の投稿への引用を撤回する」と「投稿したあとに引用の許可を変える」。

/// [post] に「この引用を撤回」を出すか。
///
/// **[post] が、自分の投稿を引用している他人の投稿**のときだけ。どの一覧に
/// 出ていても同じ条件で出る（タイムライン・通知・引用の一覧）。
///
/// - 自分の投稿は対象外（自分で引用を外したいなら、投稿を消せば済む）
/// - 引用先が見えていない（撤回済み・削除済み・承認待ちなど）ものには出さない
bool canRevokeQuote(Post post, User? me) {
  if (me == null) return false;
  if (post.author.id == me.id) return false;
  final quoted = post.quote;
  return quoted != null && quoted.author.id == me.id;
}

/// [post] に「引用の許可を変更」を出すか。
///
/// 自分の、公開か未収載の投稿だけ。⚠ フォロワー限定・指名の投稿は、サーバーが
/// 引用を許さない（許可は常に「許可しない」）ので、変える口を出さない。
/// ⚠ 引用の許可を返さないサーバー（Mastodon 4.5 未満・[Post.quoteApprovalPolicy]
/// が null）にも出さない。
bool canChangeQuoteApproval(Post post, User? me) {
  if (me == null || post.author.id != me.id) return false;
  if (post.quoteApprovalPolicy == null) return false;
  return post.scope == PostScope.public || post.scope == PostScope.unlisted;
}

/// 引用を撤回するかを確かめる。⚠ 撤回は取り消せないので、必ず挟む。
///
/// ⚠ 長押しシートを閉じたあとに呼ばれるので、その間にタイルが破棄されていたら
/// 何もしない（撤回しない側に倒す）。
Future<bool> confirmRevokeQuote(BuildContext context) async {
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('引用の撤回'),
      content: const Text(
        'この投稿から、あなたの投稿の引用を外します。'
        '相手の投稿は残りますが、あなたの投稿は表示されなくなります。\n\n'
        '撤回は取り消せません。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('撤回'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 引用の許可を選ばせる。変えなかった（同じものを選んだ・閉じた）ら null。
Future<String?> pickQuoteApprovalPolicy(
  BuildContext context, {
  required String current,
}) async {
  if (!context.mounted) return null;
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('引用の許可'),
      children: [
        for (final entry in quoteApprovalLabels.entries)
          ListTile(
            leading: Icon(
              entry.key == current
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(entry.value),
            onTap: () => Navigator.of(ctx).pop(entry.key),
          ),
      ],
    ),
  );
  return picked == null || picked == current ? null : picked;
}
