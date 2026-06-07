import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../provider/account_manager_provider.dart';
import '../util/annict_link.dart';
import 'annict_record_screen.dart';
import 'annict_review_screen.dart';

/// エピソード行の操作メニュー (#593)。`ListTile.trailing` にアイコンを並べると
/// スマホ縦持ちで窮屈になるため PopupMenuButton に集約する。
enum _EpisodeAction { copySubtitle, copyHashtag, openHashtag, annictRecord }

/// Screen for browsing Annict works and episodes.
/// Returns the selected episode's command_toot via context.pop().
class EpisodeBrowserScreen extends ConsumerStatefulWidget {
  const EpisodeBrowserScreen({super.key});

  @override
  ConsumerState<EpisodeBrowserScreen> createState() =>
      _EpisodeBrowserScreenState();
}

class _EpisodeBrowserScreenState extends ConsumerState<EpisodeBrowserScreen> {
  final _controller = TextEditingController();
  List<AnnictWork>? _works;
  bool _loading = false;
  String? _error;

  // Episode list state (null = showing works list)
  AnnictWork? _selectedWork;
  List<AnnictEpisode>? _episodes;
  bool _episodesLoading = false;
  String? _episodesError;

  @override
  void initState() {
    super.initState();
    _searchWorks();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  MulukhiyaService? get _mulukhiya => ref.read(currentMulukhiyaProvider);

  Future<void> _searchWorks() async {
    final mulukhiya = _mulukhiya;
    if (mulukhiya == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final keyword = _controller.text.trim();
      final works = await mulukhiya.searchWorks(
        keyword: keyword.isEmpty ? null : keyword,
      );
      if (mounted) setState(() => _works = works);
    } catch (e) {
      debugPrint('Episode browser search error: $e');
      if (mounted) {
        final status = e is DioException ? e.response?.statusCode : null;
        final isAuthError = status == 401 || status == 403;
        setState(() {
          _error = isAuthError ? null : '作品の検索に失敗しました';
          if (isAuthError) _showAnnictAuthPrompt();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showAnnictAuthPrompt() async {
    final linked = await runAnnictLinkFlow(context, ref);
    if (linked && mounted) _searchWorks();
  }

  /// 感想投稿画面へ遷移する。未連携 ([linked] == false) の場合はまず Annict
  /// 連携フローを促し、連携できたら record 画面へ進む (#611)。
  Future<void> _openAnnictRecord(
    AnnictEpisode ep,
    String episodeLabel,
    bool linked,
  ) async {
    if (!linked) {
      final justLinked = await runAnnictLinkFlow(context, ref);
      if (!justLinked || !mounted) return;
    }
    context.push(
      '/annict/record',
      extra: AnnictRecordScreenArgs(
        episodeId: ep.annictId,
        workTitle: _selectedWork!.title,
        episodeLabel: episodeLabel,
      ),
    );
  }

  /// 作品全体感想 (review) 画面へ遷移する (#592)。review は作品単位なので
  /// episode を選ばず作品から直接開く。劇場版など episode が無い作品はこちらが
  /// 唯一の感想投稿導線になる。未連携時は record と同様にまず連携を促す (#611)。
  Future<void> _openAnnictReview(AnnictWork work, bool linked) async {
    if (!linked) {
      final justLinked = await runAnnictLinkFlow(context, ref);
      if (!justLinked || !mounted) return;
    }
    context.push(
      '/annict/review',
      extra: AnnictReviewScreenArgs(
        workId: work.annictId,
        workTitle: work.title,
      ),
    );
  }

  Future<void> _selectWork(AnnictWork work) async {
    final mulukhiya = _mulukhiya;
    if (mulukhiya == null) return;

    setState(() {
      _selectedWork = work;
      _episodesLoading = true;
      _episodesError = null;
    });

    try {
      final episodes = await mulukhiya.getEpisodes(work.annictId);
      if (mounted) setState(() => _episodes = episodes);
    } catch (e) {
      debugPrint('Episode load error: $e');
      if (mounted) setState(() => _episodesError = 'エピソードの取得に失敗しました');
    } finally {
      if (mounted) setState(() => _episodesLoading = false);
    }
  }

  void _backToWorks() {
    setState(() {
      _selectedWork = null;
      _episodes = null;
      _episodesError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedWork != null) {
      return _buildEpisodeView();
    }
    return _buildWorksView();
  }

  Widget _buildWorksView() {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '作品を検索...',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _searchWorks(),
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _searchWorks,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: _buildWorksBody(),
    );
  }

  Widget _buildWorksBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _searchWorks, child: const Text('再試行')),
            ],
          ),
        ),
      );
    }
    if (_works == null || _works!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.live_tv, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                '作品が見つかりませんでした',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _works!.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final work = _works![index];
        return ListTile(
          leading: const Icon(Icons.movie),
          title: Text(work.title),
          subtitle: work.seasonYear != null
              ? Text('${work.seasonYear}年')
              : null,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _selectWork(work),
        );
      },
    );
  }

  /// 先頭の `#` を除いた素のタグ文字列。コピーは `#tag`、TL 遷移は素のタグを使う。
  String _bareHashtag(String raw) => raw.replaceFirst('#', '');

  void _copyText(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openHashtagTimeline(String hashtag) {
    context.push('/hashtag/${_bareHashtag(hashtag)}');
  }

  /// エピソード行の操作 (#593)。コピー / TL 遷移 / 感想投稿を PopupMenuButton に
  /// 集約する。該当する操作が一つも無ければ null（trailing なし）。
  Widget? _buildEpisodeActions(
    AnnictEpisode ep,
    String subtitle, {
    required bool showAnnictRecord,
    required bool annictLinked,
  }) {
    final hasSubtitle = ep.title != null;
    final hasHashtag = ep.hashtag != null;
    if (!hasSubtitle && !hasHashtag && !showAnnictRecord) return null;

    return PopupMenuButton<_EpisodeAction>(
      icon: const Icon(Icons.more_vert),
      tooltip: '操作',
      onSelected: (action) {
        switch (action) {
          case _EpisodeAction.copySubtitle:
            _copyText(ep.title!, 'サブタイトルをコピーしました');
          case _EpisodeAction.copyHashtag:
            _copyText('#${_bareHashtag(ep.hashtag!)}', 'ハッシュタグをコピーしました');
          case _EpisodeAction.openHashtag:
            _openHashtagTimeline(ep.hashtag!);
          case _EpisodeAction.annictRecord:
            _openAnnictRecord(ep, subtitle, annictLinked);
        }
      },
      itemBuilder: (context) => [
        if (hasSubtitle)
          const PopupMenuItem(
            value: _EpisodeAction.copySubtitle,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.copy),
              title: Text('サブタイトルをコピー'),
            ),
          ),
        if (hasHashtag) ...[
          const PopupMenuItem(
            value: _EpisodeAction.copyHashtag,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.tag),
              title: Text('ハッシュタグをコピー'),
            ),
          ),
          const PopupMenuItem(
            value: _EpisodeAction.openHashtag,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.dynamic_feed),
              title: Text('ハッシュタグのタイムライン'),
            ),
          ),
        ],
        if (showAnnictRecord)
          PopupMenuItem(
            value: _EpisodeAction.annictRecord,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.rate_review_outlined),
              title: Text(annictLinked ? 'Annict に感想投稿' : 'Annict と連携'),
            ),
          ),
      ],
    );
  }

  Widget _buildEpisodeView() {
    final work = _selectedWork!;
    final mulukhiya = _mulukhiya;
    // review は作品単位なので episode の有無に関わらず作品を開いていれば出す。
    // 未連携でも隠さず、押下時に連携フローを促す (record と同じ方針、#611)。
    final showAnnictReview = mulukhiya?.annictEnabled ?? false;
    final annictLinked = mulukhiya?.annictLinked ?? false;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _backToWorks,
        ),
        title: Text(work.title),
        actions: [
          if (showAnnictReview)
            IconButton(
              icon: const Icon(Icons.rate_review_outlined),
              tooltip: annictLinked ? '作品の感想 (Annict)' : 'Annict と連携',
              onPressed: () => _openAnnictReview(work, annictLinked),
            ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '番組名をコピー',
            onPressed: () => _copyText(work.title, '番組名をコピーしました'),
          ),
          if (work.hashtag != null) ...[
            IconButton(
              icon: const Icon(Icons.tag),
              tooltip: 'ハッシュタグをコピー',
              onPressed: () => _copyText(
                '#${_bareHashtag(work.hashtag!)}',
                'ハッシュタグをコピーしました',
              ),
            ),
            IconButton(
              icon: const Icon(Icons.dynamic_feed),
              tooltip: 'ハッシュタグのタイムライン',
              onPressed: () => _openHashtagTimeline(work.hashtag!),
            ),
          ],
        ],
      ),
      body: _buildEpisodesBody(),
    );
  }

  Widget _buildEpisodesBody() {
    if (_episodesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_episodesError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_episodesError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _selectWork(_selectedWork!),
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      );
    }
    if (_episodes == null || _episodes!.isEmpty) {
      // 劇場版などエピソードに分かれない作品はここに来る。record の投稿先が
      // ないため、Annict 対応サーバーなら作品全体感想 (review) の導線を出す
      // (#592)。AppBar のアイコンだけだと発見されにくいので空状態にも明示。
      final mulukhiya = _mulukhiya;
      final showAnnictReview = mulukhiya?.annictEnabled ?? false;
      final annictLinked = mulukhiya?.annictLinked ?? false;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('エピソードが見つかりませんでした', textAlign: TextAlign.center),
              if (showAnnictReview) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.rate_review_outlined),
                  label: Text(annictLinked ? '作品全体の感想を書く' : 'Annict と連携'),
                  onPressed: () =>
                      _openAnnictReview(_selectedWork!, annictLinked),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // 感想投稿ボタンはサーバーが Annict 対応 (annictEnabled) のときに出す。
    // 当該ユーザーが未連携 (annictLinked == false) の場合は隠さず、押下時に
    // 連携フローを促す (#611)。旧モロヘイヤは annictLinked が true に
    // フォールバックし従来どおり record 画面へ直行する。
    final mulukhiya = _mulukhiya;
    final showAnnictRecord = mulukhiya?.annictEnabled ?? false;
    final annictLinked = mulukhiya?.annictLinked ?? false;

    return ListView.separated(
      itemCount: _episodes!.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final ep = _episodes![index];
        final subtitle = [
          if (ep.numberText != null) ep.numberText!,
          if (ep.title != null) ep.title!,
        ].join(' ');

        return ListTile(
          leading: const Icon(Icons.play_circle_outline),
          title: Text(subtitle.isNotEmpty ? subtitle : 'エピソード ${ep.annictId}'),
          trailing: _buildEpisodeActions(
            ep,
            subtitle,
            showAnnictRecord: showAnnictRecord,
            annictLinked: annictLinked,
          ),
          onTap: () {
            if (ep.commandToot != null) {
              context.pop(ep.commandToot);
            }
          },
        );
      },
    );
  }
}
