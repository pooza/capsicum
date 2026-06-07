import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../provider/account_manager_provider.dart';
import '../../util/exception_scrub.dart';
import '../util/annict_link.dart';

/// Annict の作品全体感想 (review) を投稿する画面 (#592)。
///
/// モロヘイヤ #4342 で実装された `POST /api/annict/review` を経由する。
/// 単話単位の [AnnictRecordScreen] (record) の作品単位ペア。劇場版のように
/// episode に分かれていない作品は record の投稿先がなく review でしか感想を
/// 残せないため、エピソードブラウザの作品から本画面へ遷移する。
/// Annict OAuth トークンはモロヘイヤ側で保持しているため、capsicum は SNS
/// アカウントの access_token を渡すだけでよい。
class AnnictReviewScreenArgs {
  /// Annict 作品 ID (数値 annictId)。
  final int workId;

  /// ヘッダに出す作品名。
  final String workTitle;

  const AnnictReviewScreenArgs({required this.workId, required this.workTitle});
}

class AnnictReviewScreen extends ConsumerStatefulWidget {
  final AnnictReviewScreenArgs args;

  const AnnictReviewScreen({super.key, required this.args});

  @override
  ConsumerState<AnnictReviewScreen> createState() => _AnnictReviewScreenState();
}

class _AnnictReviewScreenState extends ConsumerState<AnnictReviewScreen> {
  final _bodyController = TextEditingController();
  AnnictRatingState? _overall;
  AnnictRatingState? _animation;
  AnnictRatingState? _music;
  AnnictRatingState? _story;
  AnnictRatingState? _character;
  bool _submitting = false;
  // 連携フロー後の自動リトライは 1 回まで。連携直後のトークン伝播遅延で
  // 再び 401/403 が返った時の無限ループを防ぐ (record 画面と同じ)。
  bool _linkRetried = false;

  @override
  void dispose() {
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    final account = ref.read(currentAccountProvider);
    if (mulukhiya == null || account == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('アカウント情報が取得できませんでした')));
      // 連携リトライ経由の再帰呼び出しでは外側が _submitting=true のまま
      // 戻ってくるので、abort 時はここでリセットしないと画面が固まる。
      if (mounted && _submitting) setState(() => _submitting = false);
      return;
    }
    final body = _bodyController.text.trim();
    if (body.isEmpty) {
      // review は record と違い「視聴済みだけ」という概念がなく、本文必須
      // (モロヘイヤ #4342 / Annict createReview の仕様)。
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('感想本文を入力してください')));
      if (mounted && _submitting) setState(() => _submitting = false);
      return;
    }

    setState(() => _submitting = true);
    try {
      await mulukhiya.postAnnictReview(
        snsToken: account.userSecret.accessToken,
        workId: widget.args.workId,
        body: body,
        ratingOverall: _overall,
        ratingAnimation: _animation,
        ratingMusic: _music,
        ratingStory: _story,
        ratingCharacter: _character,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Annict に感想を投稿しました')));
      // record 画面と同じく、感想投稿の終着点はタイムラインなので stack を
      // 畳んで /home へ (深い導線から何度も戻らせない、#584)。
      context.go('/home');
    } on DioException catch (e, st) {
      if (!mounted) return;
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        // Annict 未連携 / トークン失効 / スコープ不足。モロヘイヤが auth/scope
        // 系をすべて 403 (Ginseng::AuthError) に正規化するため 401/403 をまとめて
        // 「要連携」とみなす。その場で連携→投稿リトライする (record と同じ)。
        // _submitting は連携フロー中も true のまま維持 (二重 POST 防止)。
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
      // 5xx はサーバ起因の異常。成功率を観測するため Sentry に上げる
      // (401/403/連携不足は通常運用なのでノイズとして送らない)。
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.args.workTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              Text('評価', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              _ratingRow('総合', _overall, (v) => setState(() => _overall = v)),
              _ratingRow(
                '映像',
                _animation,
                (v) => setState(() => _animation = v),
              ),
              _ratingRow('音楽', _music, (v) => setState(() => _music = v)),
              _ratingRow('物語', _story, (v) => setState(() => _story = v)),
              _ratingRow(
                'キャラクター',
                _character,
                (v) => setState(() => _character = v),
              ),
              const SizedBox(height: 16),
              Text('感想', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _bodyController,
                enabled: !_submitting,
                maxLines: null,
                minLines: 6,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '感想を入力 (必須)',
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

  /// 1 軸ぶんのレーティング行 (ラベル + 4 段階チップ)。総合 + 4 軸で 5 行
  /// 並べるため record 画面の Wrap より縦に積む形にして横幅を節約する。
  Widget _ratingRow(
    String label,
    AnnictRatingState? current,
    ValueChanged<AnnictRatingState?> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              children: [
                _ratingChip(
                  AnnictRatingState.great,
                  'とても良い',
                  current,
                  onChanged,
                ),
                _ratingChip(AnnictRatingState.good, '良い', current, onChanged),
                _ratingChip(
                  AnnictRatingState.average,
                  '普通',
                  current,
                  onChanged,
                ),
                _ratingChip(AnnictRatingState.bad, '良くない', current, onChanged),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _ratingChip(
    AnnictRatingState value,
    String label,
    AnnictRatingState? current,
    ValueChanged<AnnictRatingState?> onChanged,
  ) {
    final selected = current == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      visualDensity: VisualDensity.compact,
      onSelected: _submitting ? null : (s) => onChanged(s ? value : null),
    );
  }
}
