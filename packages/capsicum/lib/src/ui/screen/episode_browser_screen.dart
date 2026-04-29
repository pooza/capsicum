import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../url_helper.dart';
import '../../provider/account_manager_provider.dart';

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
    final mulukhiya = _mulukhiya;
    if (mulukhiya == null) return;

    final account = ref.read(currentAccountProvider);
    if (account == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Annict 連携'),
        content: const Text(
          'エピソードブラウザを使うには Annict アカウントとの連携が必要です。\n\n'
          'ブラウザで Annict の認可画面を開き、表示されるコードを入力してください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('連携する'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final oauthUri = await mulukhiya.getAnnictOAuthUri();
      final uri = Uri.parse(oauthUri);
      if (!await launchUrlSafely(uri, mode: LaunchMode.externalApplication)) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('ブラウザを開けませんでした')));
        }
        return;
      }

      if (!mounted) return;

      final code = await _showCodeInputDialog();
      if (code == null || code.trim().isEmpty || !mounted) return;

      setState(() => _loading = true);
      await mulukhiya.authenticateAnnict(
        snsToken: account.userSecret.accessToken,
        annictCode: code.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Annict 連携が完了しました')));
        _searchWorks();
      }
    } catch (e) {
      debugPrint('Annict auth error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Annict 連携に失敗しました')));
        setState(() => _loading = false);
      }
    }
  }

  Future<String?> _showCodeInputDialog() async {
    final codeController = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('認可コードの入力'),
          content: TextField(
            controller: codeController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Annict で表示されたコードを貼り付け',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, codeController.text),
              child: const Text('認証'),
            ),
          ],
        ),
      );
    } finally {
      codeController.dispose();
    }
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
