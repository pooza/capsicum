import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../provider/account_manager_provider.dart';

/// Screen for browsing Annict works and episodes.
/// Returns the selected episode's command_toot YAML via Navigator.pop().
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

  @override
  void initState() {
    super.initState();
    // Load default works on open.
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
        final isAuthError = e.toString().contains('401');
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
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
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

  void _showEpisodes(AnnictWork work) {
    Navigator.of(context).push(
      MaterialPageRoute<String>(
        builder: (_) => _EpisodeListScreen(
          mulukhiya: _mulukhiya!,
          work: work,
        ),
      ),
    ).then((commandToot) {
      if (commandToot != null && mounted) {
        Navigator.pop(context, commandToot);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
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
              FilledButton(
                onPressed: _searchWorks,
                child: const Text('再試行'),
              ),
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
          onTap: () => _showEpisodes(work),
        );
      },
    );
  }
}

class _EpisodeListScreen extends StatefulWidget {
  final MulukhiyaService mulukhiya;
  final AnnictWork work;

  const _EpisodeListScreen({
    required this.mulukhiya,
    required this.work,
  });

  @override
  State<_EpisodeListScreen> createState() => _EpisodeListScreenState();
}

class _EpisodeListScreenState extends State<_EpisodeListScreen> {
  List<AnnictEpisode>? _episodes;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadEpisodes();
  }

  Future<void> _loadEpisodes() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final episodes = await widget.mulukhiya.getEpisodes(
        widget.work.annictId,
      );
      if (mounted) setState(() => _episodes = episodes);
    } catch (e) {
      debugPrint('Episode load error: $e');
      if (mounted) setState(() => _error = 'エピソードの取得に失敗しました');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.work.title),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
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
              FilledButton(
                onPressed: _loadEpisodes,
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
          title: Text(
            subtitle.isNotEmpty ? subtitle : 'エピソード ${ep.annictId}',
          ),
          onTap: () {
            if (ep.commandToot != null) {
              Navigator.pop(context, ep.commandToot);
            }
          },
        );
      },
    );
  }
}
