import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../provider/account_manager_provider.dart';
import '../util/annict_link.dart';
import 'annict_record_screen.dart';

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

  Widget _buildEpisodeView() {
    final work = _selectedWork!;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _backToWorks,
        ),
        title: Text(work.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '番組名をコピー',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: work.title));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('番組名をコピーしました')));
            },
          ),
          if (work.hashtag != null)
            IconButton(
              icon: const Icon(Icons.tag),
              tooltip: 'ハッシュタグをコピー',
              onPressed: () {
                final tag = '#${work.hashtag!.replaceFirst('#', '')}';
                Clipboard.setData(ClipboardData(text: tag));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('ハッシュタグをコピーしました')));
              },
            ),
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
      return const Center(child: Text('エピソードが見つかりませんでした'));
    }

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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ep.title != null)
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: 'サブタイトルをコピー',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: ep.title!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('サブタイトルをコピーしました')),
                    );
                  },
                ),
              if (ep.hashtag != null)
                IconButton(
                  icon: const Icon(Icons.tag, size: 20),
                  tooltip: 'ハッシュタグTL',
                  onPressed: () {
                    final tag = ep.hashtag!.replaceFirst('#', '');
                    context.push('/hashtag/$tag');
                  },
                ),
              IconButton(
                icon: const Icon(Icons.rate_review_outlined, size: 20),
                tooltip: 'Annict に感想投稿',
                onPressed: () {
                  context.push(
                    '/annict/record',
                    extra: AnnictRecordScreenArgs(
                      episodeId: ep.annictId,
                      workTitle: _selectedWork!.title,
                      episodeLabel: subtitle,
                    ),
                  );
                },
              ),
            ],
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
