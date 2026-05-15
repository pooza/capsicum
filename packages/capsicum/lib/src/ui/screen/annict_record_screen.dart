import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
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
      if (confirm != true || !mounted) return;
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
    } on DioException catch (e) {
      if (!mounted) return;
      if (e.response?.statusCode == 401) {
        // Annict 未連携 / トークン失効。番組表→感想投稿が主要導線なので
        // エピソードブラウザに寄り道させず、その場で連携フローを起動して
        // 成功したら投稿をリトライする (#298)。
        setState(() => _submitting = false);
        final linked = await runAnnictLinkFlow(context, ref);
        if (linked && mounted) _submit();
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Annict への投稿に失敗しました')));
      setState(() => _submitting = false);
    } catch (_) {
      if (!mounted) return;
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
