import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/exception_scrub.dart';
import '../util/annict_link.dart';

/// Annict 視聴記録 (感想・レーティング) を投稿する画面 (#298)。
///
/// モロヘイヤ #4227 で実装された `POST /api/annict/record` を経由する。
/// Annict OAuth トークンはモロヘイヤ側で保持しているため、capsicum は
/// SNS アカウントの access_token を渡すだけでよい。エピソード ID と
/// 表示用ラベルを呼び出し側 (エピソードブラウザ / 番組タグセット) から
/// extra で受け取る。
class AnnictRecordScreenArgs {
  final int episodeId;

  /// ヘッダに出す作品名 (Annict の work title やモロヘイヤ番組表の series)。
  final String workTitle;

  /// エピソード本体のラベル (例: "第3話 サブタイトル")。空 OK。
  final String episodeLabel;

  const AnnictRecordScreenArgs({
    required this.episodeId,
    required this.workTitle,
    this.episodeLabel = '',
  });
}

class AnnictRecordScreen extends ConsumerStatefulWidget {
  final AnnictRecordScreenArgs args;

  const AnnictRecordScreen({super.key, required this.args});

  @override
  ConsumerState<AnnictRecordScreen> createState() => _AnnictRecordScreenState();
}

class _AnnictRecordScreenState extends ConsumerState<AnnictRecordScreen> {
  final _commentController = TextEditingController();
  AnnictRatingState? _rating;
  bool _submitting = false;
  // 連携フロー後の自動リトライは 1 回まで。連携直後のトークン伝播遅延で
  // 再び 401/403 が返った時の無限ループを防ぐ。
  bool _linkRetried = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    final account = ref.read(currentAccountProvider);
    if (mulukhiya == null || account == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('アカウント情報が取得できませんでした')));
      // 連携リトライ経由 (#298) の再帰呼び出しでは外側が _submitting=true の
      // まま戻ってくるので、abort 時はここでリセットしないと画面が固まる。
      if (mounted && _submitting) setState(() => _submitting = false);
      return;
    }
    final comment = _commentController.text.trim();
    if (comment.isEmpty && _rating == null) {
      // 感想 / レーティングのどちらも未入力で submit すると Annict 側で
      // 「視聴済み」だけ立つ挙動 (mulukhiya #4227 の API 仕様)。
      // ユーザー誤操作の保険として確認ダイアログを挟む。
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('視聴済みとして記録'),
          content: const Text('感想・レーティングが空のままです。視聴済みフラグだけ立てて Annict に記録しますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('記録する'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) {
        // 連携リトライ経由 (#298) の再帰呼び出しでは外側が _submitting=true の
        // まま戻ってくるので、キャンセル時はここでリセットしないと画面が固まる。
        if (mounted && _submitting) setState(() => _submitting = false);
        return;
      }
    }

    setState(() => _submitting = true);
    try {
      await mulukhiya.postAnnictRecord(
        snsToken: account.userSecret.accessToken,
        episodeId: widget.args.episodeId,
        comment: comment.isNotEmpty ? comment : null,
        ratingState: _rating,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Annict に感想を投稿しました')));
      context.pop();
    } on DioException catch (e, st) {
      if (!mounted) return;
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        // Annict 未連携 / トークン失効 / スコープ不足。モロヘイヤが auth/scope
        // 系をすべて 403 (Ginseng::AuthError) に正規化して返すため、401/403 を
        // まとめて「要連携」とみなす (episode_browser_screen と同じ判定)。
        // 番組表→感想投稿が主要導線なのでその場で連携→投稿リトライする (#298)。
        // _submitting は連携フロー中も true のまま維持する。false に戻すと
        // ブラウザ/コード入力中に投稿ボタンが再活性化し、二重 POST する。
        final linked = await runAnnictLinkFlow(context, ref);
        if (!mounted) return;
        if (linked && !_linkRetried) {
          _linkRetried = true;
          await _submit();
          return;
        }
        setState(() => _submitting = false);
        return;
      }
      // 5xx はサーバ起因の異常。主要導線 (#298) の成功率を観測するため
      // Sentry に上げる (401/403/連携不足は通常運用なのでノイズとして送らない)。
      if (status != null && status >= 500) {
        Sentry.captureException(scrubException(e), stackTrace: st);
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Annict への投稿に失敗しました')));
      setState(() => _submitting = false);
    } catch (e, st) {
      if (!mounted) return;
      Sentry.captureException(scrubException(e), stackTrace: st);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Annict への投稿に失敗しました')));
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Annict に感想を投稿'),
        actions: [
          TextButton(
            onPressed: _submitting ? null : _submit,
            child: const Text('投稿'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.args.workTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (widget.args.episodeLabel.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  widget.args.episodeLabel,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 16),
              Text('評価', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _ratingChip(AnnictRatingState.great, 'とても良い'),
                  _ratingChip(AnnictRatingState.good, '良い'),
                  _ratingChip(AnnictRatingState.average, '普通'),
                  _ratingChip(AnnictRatingState.bad, '良くない'),
                ],
              ),
              const SizedBox(height: 16),
              Text('感想', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _commentController,
                enabled: !_submitting,
                maxLines: 8,
                minLines: 5,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '感想を入力 (任意)',
                ),
              ),
              if (_submitting) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _ratingChip(AnnictRatingState value, String label) {
    final selected = _rating == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: _submitting
          ? null
          : (s) => setState(() => _rating = s ? value : null),
    );
  }
}
