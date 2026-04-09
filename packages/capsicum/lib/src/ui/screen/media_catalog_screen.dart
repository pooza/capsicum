import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../url_helper.dart';
import '../../provider/account_manager_provider.dart';
import '../widget/emoji_text.dart';

class MediaCatalogScreen extends ConsumerStatefulWidget {
  const MediaCatalogScreen({super.key});

  @override
  ConsumerState<MediaCatalogScreen> createState() => _MediaCatalogScreenState();
}

class _MediaCatalogScreenState extends ConsumerState<MediaCatalogScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  List<MediaCatalogItem> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  bool _personOnly = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  MulukhiyaService? get _mulukhiya => ref.read(currentMulukhiyaProvider);

  void _onScroll() {
    if (_loadingMore || !_hasMore) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    final mulukhiya = _mulukhiya;
    if (mulukhiya == null) return;

    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
    });

    try {
      final query = _searchController.text.trim();
      final result = await mulukhiya.getMediaCatalog(
        page: 1,
        query: query.isEmpty ? null : query,
        personOnly: _personOnly,
      );
      if (mounted) {
        setState(() {
          _items = result.items;
          _hasMore = result.hasNext;
        });
      }
    } catch (e) {
      debugPrint('Media catalog load error: $e');
      if (mounted) setState(() => _error = 'メディアカタログの取得に失敗しました');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final mulukhiya = _mulukhiya;
    if (mulukhiya == null || _loadingMore || !_hasMore) return;

    setState(() => _loadingMore = true);

    try {
      final nextPage = _page + 1;
      final query = _searchController.text.trim();
      final result = await mulukhiya.getMediaCatalog(
        page: nextPage,
        query: query.isEmpty ? null : query,
        personOnly: _personOnly,
      );
      if (mounted) {
        setState(() {
          _page = nextPage;
          _items.addAll(result.items);
          _hasMore = result.hasNext;
        });
      }
    } catch (e) {
      debugPrint('Media catalog loadMore error: $e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'メディアを検索...',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _load(),
        ),
        actions: [
          IconButton(
            icon: Icon(_personOnly ? Icons.person : Icons.person_outline),
            tooltip: _personOnly ? '全メディア' : '人物のみ',
            onPressed: () {
              setState(() => _personOnly = !_personOnly);
              _load();
            },
          ),
          IconButton(
            onPressed: _loading ? null : _load,
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
              FilledButton(onPressed: _load, child: const Text('再試行')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'メディアが見つかりませんでした',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _load(),
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Center(child: CircularProgressIndicator());
          }
          return _MediaThumbnail(
            item: _items[index],
            onTap: () => _showDetail(_items[index]),
          );
        },
      ),
    );
  }

  void _showDetail(MediaCatalogItem item) {
    final account = ref.read(currentAccountProvider);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _MediaDetailSheet(item: item, fallbackHost: account?.key.host),
    );
  }
}

/// Whether the URL points to an image that [Image.network] can render.
/// Mastodon video thumbnails are `.mp4` files, which cannot be displayed
/// as images.
bool _isImageUrl(String url) {
  final lower = url.toLowerCase();
  return !lower.endsWith('.mp4') &&
      !lower.endsWith('.webm') &&
      !lower.endsWith('.mp3') &&
      !lower.endsWith('.ogg');
}

class _MediaThumbnail extends StatelessWidget {
  final MediaCatalogItem item;
  final VoidCallback onTap;

  const _MediaThumbnail({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = _resolveImageUrl(item);

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl != null)
            Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.broken_image)),
              ),
            )
          else
            Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Center(
                child: Icon(
                  _iconForType(item.mediatype),
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (item.mediatype == 'video')
            Positioned(
              right: 4,
              bottom: 4,
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white.withValues(alpha: 0.9),
                size: 20,
              ),
            ),
          if (item.mediatype == 'audio')
            Positioned(
              right: 4,
              bottom: 4,
              child: Icon(
                Icons.audiotrack,
                color: Colors.white.withValues(alpha: 0.9),
                size: 20,
              ),
            ),
        ],
      ),
    );
  }

  /// Returns a displayable image URL, or null if no suitable image is
  /// available (e.g. audio files or video thumbnails that are .mp4).
  static String? _resolveImageUrl(MediaCatalogItem item) {
    if (item.thumbnailUrl != null && _isImageUrl(item.thumbnailUrl!)) {
      return item.thumbnailUrl;
    }
    if (item.mediatype == 'image' && _isImageUrl(item.url)) {
      return item.url;
    }
    return null;
  }

  static IconData _iconForType(String? mediatype) {
    switch (mediatype) {
      case 'video':
        return Icons.videocam;
      case 'audio':
        return Icons.audiotrack;
      default:
        return Icons.insert_drive_file;
    }
  }
}

class _MediaDetailSheet extends ConsumerWidget {
  final MediaCatalogItem item;
  final String? fallbackHost;

  const _MediaDetailSheet({required this.item, this.fallbackHost});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final imageUrl = _resolveDetailImageUrl(item);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Center(child: Icon(Icons.broken_image)),
                  ),
                ),
              ),
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Icon(
                      item.mediatype == 'video'
                          ? Icons.videocam
                          : item.mediatype == 'audio'
                          ? Icons.audiotrack
                          : Icons.insert_drive_file,
                      size: 48,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (item.fileName != null)
            _detailRow(Icons.insert_drive_file, item.fileName!),
          if (item.fileSizeStr != null)
            _detailRow(Icons.data_usage, item.fileSizeStr!),
          if (item.pixelSize != null)
            _detailRow(Icons.aspect_ratio, item.pixelSize!),
          if (item.duration != null)
            _detailRow(Icons.timer, '${item.duration!.toStringAsFixed(1)} 秒'),
          if (item.type != null) _detailRow(Icons.description, item.type!),
          if (item.createdAt != null)
            _detailRow(Icons.calendar_today, item.createdAt!),
          if (item.accountDisplayName != null || item.accountUsername != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: GestureDetector(
                onTap: item.accountUsername != null
                    ? () => _openProfile(context, ref, item.accountUsername!)
                    : null,
                child: Row(
                  children: [
                    const Icon(Icons.person, size: 18, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: EmojiText(
                        item.accountDisplayName ?? item.accountUsername!,
                        fallbackHost: fallbackHost,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (item.statusBody != null && item.statusBody!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                item.statusBody!,
                style: theme.textTheme.bodyMedium,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('元の投稿'),
                  onPressed: item.statusPublicUrl != null
                      ? () {
                          final uri = Uri.tryParse(item.statusPublicUrl!);
                          if (uri != null) launchUrlSafely(uri);
                        }
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('メディア'),
                  onPressed: () => _openMediaViewer(context, item),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Returns a displayable image URL for the detail view.
  static String? _resolveDetailImageUrl(MediaCatalogItem item) {
    if (item.thumbnailUrl != null && _isImageUrl(item.thumbnailUrl!)) {
      return item.thumbnailUrl;
    }
    if (item.mediatype == 'image' && _isImageUrl(item.url)) {
      return item.url;
    }
    return null;
  }

  void _openMediaViewer(BuildContext context, MediaCatalogItem item) {
    final type = switch (item.mediatype) {
      'video' => AttachmentType.video,
      'audio' => AttachmentType.audio,
      _ => AttachmentType.image,
    };
    final attachment = Attachment(
      id: item.id,
      type: type,
      url: item.url,
      previewUrl: item.thumbnailUrl,
    );
    Navigator.of(context).pop(); // close bottom sheet
    context.push(
      '/media',
      extra: {
        'attachments': [attachment],
        'initialIndex': 0,
      },
    );
  }

  Future<void> _openProfile(
    BuildContext context,
    WidgetRef ref,
    String username,
  ) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    Navigator.of(context).pop(); // close bottom sheet
    try {
      final user = await adapter.getUser(username);
      if (user != null && context.mounted) {
        context.push('/profile', extra: user);
      }
    } catch (e) {
      debugPrint('Failed to open profile: $e');
    }
  }

  Widget _detailRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
