import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../provider/account_manager_provider.dart';

class MediaViewerScreen extends ConsumerStatefulWidget {
  final List<Attachment> attachments;
  final int initialIndex;
  final String? postAuthorId;
  final String? postId;

  const MediaViewerScreen({
    super.key,
    required this.attachments,
    this.initialIndex = 0,
    this.postAuthorId,
    this.postId,
  });

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;
  late List<Attachment> _attachments;
  bool _modified = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _attachments = List.of(widget.attachments);
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool get _canEdit {
    if (widget.postAuthorId == null || widget.postId == null) return false;
    final currentUser = ref.read(currentAccountProvider)?.user;
    if (currentUser == null) return false;
    final adapter = ref.read(currentAdapterProvider);
    return currentUser.id == widget.postAuthorId &&
        adapter is MediaUpdateSupport;
  }

  Future<void> _editDescription() async {
    final attachment = _attachments[_currentIndex];
    final controller = TextEditingController(
      text: attachment.description ?? '',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('メディアの説明を編集'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '説明を入力…',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result == null || !mounted) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! MediaUpdateSupport) return;
    final mediaSupport = adapter as MediaUpdateSupport;

    try {
      final updated = await mediaSupport.updateAttachmentDescription(
        attachment.id,
        result,
        postId: widget.postId!,
      );
      setState(() {
        _attachments[_currentIndex] = updated;
        _modified = true;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('説明を更新しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新に失敗しました: $e')));
      }
    }
  }

  void _popWithResult() {
    if (_modified) {
      context.pop(_attachments);
    } else {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachment = _attachments[_currentIndex];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _popWithResult();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.black54,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _popWithResult,
          ),
          title: widget.attachments.length > 1
              ? Text('${_currentIndex + 1} / ${widget.attachments.length}')
              : null,
          actions: [
            if (_canEdit)
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'メディアの説明を編集',
                onPressed: _editDescription,
              ),
          ],
        ),
        body: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: _attachments.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) {
                final a = _attachments[index];
                if (a.type == AttachmentType.video) {
                  return _VideoPage(url: a.url);
                }
                if (a.type == AttachmentType.audio) {
                  return _AudioPage(url: a.url);
                }
                return InteractiveViewer(
                  minScale: 1.0,
                  maxScale: 4.0,
                  child: Center(
                    child: Image.network(
                      a.url,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 64,
                      ),
                    ),
                  ),
                );
              },
            ),
            if (attachment.description != null &&
                attachment.description!.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    32,
                    16,
                    MediaQuery.of(context).padding.bottom + 16,
                  ),
                  child: Text(
                    attachment.description!,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  final String url;

  const _VideoPage({required this.url});

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  bool _showControls = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize()
          .then((_) {
            if (mounted) {
              setState(() => _initialized = true);
              _controller.addListener(_onVideoUpdate);
              _controller.play();
              _hideControlsAfterDelay();
            }
          })
          .catchError((e) {
            if (mounted) setState(() => _error = e.toString());
          });
  }

  void _onVideoUpdate() {
    if (mounted) setState(() {});
  }

  void _hideControlsAfterDelay() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _controller.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onVideoUpdate);
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller.value.isPlaying) {
      _controller.pause();
      setState(() => _showControls = true);
    } else {
      _controller.play();
      _hideControlsAfterDelay();
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 48),
            const SizedBox(height: 8),
            Text('動画を読み込めません', style: const TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _controller.value.aspectRatio,
        child: GestureDetector(
          onTap: () => setState(() => _showControls = !_showControls),
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_controller),
              // Play/pause button
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: GestureDetector(
                  onTap: _togglePlayPause,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.black38,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      _controller.value.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),
              // Bottom control bar
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black54, Colors.transparent],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        VideoProgressIndicator(
                          _controller,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: Colors.white,
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.white10,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_controller.value.position),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              _formatDuration(_controller.value.duration),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioPage extends StatefulWidget {
  final String url;

  const _AudioPage({required this.url});

  @override
  State<_AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends State<_AudioPage> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize()
          .then((_) {
            if (mounted) {
              setState(() => _initialized = true);
              _controller.addListener(_onUpdate);
              _controller.play();
            }
          })
          .catchError((e) {
            if (mounted) setState(() => _error = e.toString());
          });
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onUpdate);
    _controller.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 48),
            const SizedBox(height: 8),
            Text('音声を読み込めません', style: const TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_note, color: Colors.white38, size: 96),
            const SizedBox(height: 32),
            GestureDetector(
              onTap: () {
                _controller.value.isPlaying
                    ? _controller.pause()
                    : _controller.play();
              },
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white12,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(16),
                child: Icon(
                  _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 48,
                ),
              ),
            ),
            const SizedBox(height: 24),
            VideoProgressIndicator(
              _controller,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: Colors.white,
                bufferedColor: Colors.white24,
                backgroundColor: Colors.white10,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_controller.value.position),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  _formatDuration(_controller.value.duration),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
