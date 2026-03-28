import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/drive_provider.dart';

class DrivePickerScreen extends ConsumerStatefulWidget {
  const DrivePickerScreen({super.key});

  @override
  ConsumerState<DrivePickerScreen> createState() => _DrivePickerScreenState();
}

class _DrivePickerScreenState extends ConsumerState<DrivePickerScreen> {
  final _scrollController = ScrollController();
  final Set<String> _selectedIds = {};
  final List<Attachment> _selectedFiles = [];

  /// Folder navigation stack: null = root.
  final List<_FolderEntry> _folderStack = [];

  String? get _currentFolderId =>
      _folderStack.isEmpty ? null : _folderStack.last.id;

  String get _currentTitle =>
      _folderStack.isEmpty ? 'ドライブ' : _folderStack.last.name;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(driveContentsProvider(_currentFolderId).notifier).loadMore();
    }
  }

  void _openFolder(DriveFolder folder) {
    setState(() {
      _folderStack.add(_FolderEntry(id: folder.id, name: folder.name));
    });
  }

  void _goBack() {
    if (_folderStack.isNotEmpty) {
      setState(() => _folderStack.removeLast());
    } else {
      Navigator.of(context).pop(<Attachment>[]);
    }
  }

  void _toggleSelection(Attachment file) {
    setState(() {
      if (_selectedIds.contains(file.id)) {
        _selectedIds.remove(file.id);
        _selectedFiles.removeWhere((f) => f.id == file.id);
      } else {
        _selectedIds.add(file.id);
        _selectedFiles.add(file);
      }
    });
  }

  void _confirm() {
    Navigator.of(context).pop(_selectedFiles);
  }

  @override
  Widget build(BuildContext context) {
    final drive = ref.watch(driveContentsProvider(_currentFolderId));
    final theme = Theme.of(context);

    return PopScope(
      canPop: _folderStack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_currentTitle),
          backgroundColor: theme.colorScheme.inversePrimary,
          leading: IconButton(
            icon: Icon(_folderStack.isEmpty ? Icons.close : Icons.arrow_back),
            onPressed: _goBack,
          ),
          actions: [
            if (_selectedIds.isNotEmpty)
              TextButton(
                onPressed: _confirm,
                child: Text('選択 (${_selectedIds.length})'),
              ),
          ],
        ),
        body: drive.when(
          data: (state) {
            final totalFolders = state.folders.length;
            final totalFiles = state.files.length;
            final totalItems =
                totalFolders + totalFiles + (state.isLoadingMore ? 1 : 0);

            if (totalFolders == 0 && totalFiles == 0) {
              return const Center(child: Text('ファイルがありません'));
            }

            return RefreshIndicator(
              onRefresh: () =>
                  ref.refresh(driveContentsProvider(_currentFolderId).future),
              child: GridView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(4),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemCount: totalItems,
                itemBuilder: (context, index) {
                  if (index < totalFolders) {
                    return _DriveFolderTile(
                      folder: state.folders[index],
                      onTap: () => _openFolder(state.folders[index]),
                    );
                  }
                  final fileIndex = index - totalFolders;
                  if (fileIndex >= totalFiles) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final file = state.files[fileIndex];
                  final selected = _selectedIds.contains(file.id);
                  return _DriveFileTile(
                    file: file,
                    selected: selected,
                    onTap: () => _toggleSelection(file),
                  );
                },
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('読み込みに失敗しました', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () =>
                        ref.invalidate(driveContentsProvider(_currentFolderId)),
                    child: const Text('再試行'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderEntry {
  final String id;
  final String name;
  const _FolderEntry({required this.id, required this.name});
}

class _DriveFolderTile extends StatelessWidget {
  final DriveFolder folder;
  final VoidCallback onTap;

  const _DriveFolderTile({required this.folder, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder, size: 40, color: theme.colorScheme.primary),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                folder.name,
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriveFileTile extends StatelessWidget {
  final Attachment file;
  final bool selected;
  final VoidCallback onTap;

  const _DriveFileTile({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewUrl = file.previewUrl ?? file.url;
    final isImage =
        file.type == AttachmentType.image || file.type == AttachmentType.gifv;
    final isVideo = file.type == AttachmentType.video;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: isImage && previewUrl.isNotEmpty
                ? Image.network(
                    previewUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Center(child: Icon(Icons.broken_image)),
                    ),
                  )
                : Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        isVideo
                            ? Icons.videocam
                            : file.type == AttachmentType.audio
                            ? Icons.audio_file
                            : Icons.insert_drive_file,
                        size: 32,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
          if (selected)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: theme.colorScheme.primary, width: 3),
                color: theme.colorScheme.primary.withValues(alpha: 0.2),
              ),
            ),
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? theme.colorScheme.primary : Colors.black38,
              ),
              padding: const EdgeInsets.all(2),
              child: Icon(
                selected ? Icons.check : Icons.circle_outlined,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
          if (file.description?.isNotEmpty == true)
            Positioned(
              bottom: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'ALT',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
