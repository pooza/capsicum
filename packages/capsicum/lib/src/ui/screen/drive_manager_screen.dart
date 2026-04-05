import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/drive_provider.dart';
import 'media_viewer_screen.dart';

class DriveManagerScreen extends ConsumerStatefulWidget {
  const DriveManagerScreen({super.key});

  @override
  ConsumerState<DriveManagerScreen> createState() => _DriveManagerScreenState();
}

class _DriveManagerScreenState extends ConsumerState<DriveManagerScreen> {
  final _scrollController = ScrollController();
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
        _scrollController.position.maxScrollExtent - 600) {
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
      Navigator.of(context).pop();
    }
  }

  void _refresh() {
    ref.invalidate(driveContentsProvider(_currentFolderId));
    setState(() {});
  }

  DriveSupport? get _drive {
    final adapter = ref.read(currentAdapterProvider);
    return adapter is DriveSupport ? adapter as DriveSupport : null;
  }

  void _openFile(Attachment file, List<Attachment> files, int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            MediaViewerScreen(attachments: files, initialIndex: index),
      ),
    );
  }

  void _showFileActions(Attachment file) {
    final messenger = ScaffoldMessenger.of(context);
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('URL をコピー'),
              onTap: () {
                Navigator.pop(sheetContext);
                Clipboard.setData(ClipboardData(text: file.url));
                messenger.showSnackBar(
                  const SnackBar(content: Text('URL をコピーしました')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('リネーム'),
              onTap: () {
                Navigator.pop(sheetContext);
                _renameFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: Text(
                file.description?.isNotEmpty == true
                    ? 'ALT テキストを編集'
                    : 'ALT テキストを追加',
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _editAltText(file);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '削除',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFolderActions(DriveFolder folder) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('開く'),
              onTap: () {
                Navigator.pop(sheetContext);
                _openFolder(folder);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('リネーム'),
              onTap: () {
                Navigator.pop(sheetContext);
                _renameFolder(folder);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '削除',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteFolder(folder);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _showTextInputDialog(
    String title,
    String initialValue,
    String hint,
  ) async {
    return showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: initialValue);
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: hint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _showRenameDialog(String title, String currentName) {
    return _showTextInputDialog(title, currentName, '名前');
  }

  Future<void> _editAltText(Attachment file) async {
    final newAlt = await _showTextInputDialog(
      'ALT テキスト',
      file.description ?? '',
      '画像の説明',
    );
    if (newAlt == null) return;
    try {
      final adapter = ref.read(currentAdapterProvider);
      if (adapter is! DriveSupport) return;
      // Use MisskeyClient.updateDriveFile with comment parameter
      final misskeyAdapter = adapter as dynamic;
      await misskeyAdapter.client.updateDriveFile(file.id, comment: newAlt);
      ref
          .read(driveContentsProvider(_currentFolderId).notifier)
          .updateFileDescription(file.id, newAlt);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作に失敗しました: $e')));
      }
    }
  }

  Future<void> _renameFile(Attachment file) async {
    final newName = await _showRenameDialog('ファイル名を変更', file.name ?? file.id);
    if (newName == null || newName.isEmpty) return;
    try {
      await _drive?.renameDriveFile(file.id, newName);
      ref
          .read(driveContentsProvider(_currentFolderId).notifier)
          .renameFile(file.id, newName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作に失敗しました: $e')));
      }
    }
  }

  Future<void> _deleteFile(Attachment file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ファイルを削除'),
        content: const Text('このファイルを削除しますか？この操作は元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _drive?.deleteDriveFile(file.id);
      ref
          .read(driveContentsProvider(_currentFolderId).notifier)
          .removeFile(file.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('削除しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('削除に失敗しました: $e')));
      }
    }
  }

  Future<void> _renameFolder(DriveFolder folder) async {
    final newName = await _showRenameDialog('フォルダ名を変更', folder.name);
    if (newName == null || newName.isEmpty) return;
    try {
      await _drive?.renameDriveFolder(folder.id, newName);
      ref
          .read(driveContentsProvider(_currentFolderId).notifier)
          .renameFolder(folder.id, newName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作に失敗しました: $e')));
      }
    }
  }

  Future<void> _deleteFolder(DriveFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('フォルダを削除'),
        content: const Text('このフォルダを削除しますか？フォルダ内にファイルがある場合は削除できません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _drive?.deleteDriveFolder(folder.id);
      ref
          .read(driveContentsProvider(_currentFolderId).notifier)
          .removeFolder(folder.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作に失敗しました: $e')));
      }
    }
  }

  Future<void> _createFolder() async {
    final name = await _showTextInputDialog('フォルダを作成', '', 'フォルダ名');
    if (name == null || name.isEmpty) return;
    try {
      await _drive?.createDriveFolder(name, parentId: _currentFolderId);
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作に失敗しました: $e')));
      }
    }
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
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: 'フォルダを作成',
              onPressed: _createFolder,
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
                    final folder = state.folders[index];
                    return _FolderTile(
                      key: ValueKey('folder-${folder.id}'),
                      folder: folder,
                      onTap: () => _openFolder(folder),
                      onLongPress: () => _showFolderActions(folder),
                    );
                  }
                  final fileIndex = index - totalFolders;
                  if (fileIndex >= totalFiles) {
                    return const Center(
                      key: ValueKey('loading'),
                      child: CircularProgressIndicator(),
                    );
                  }
                  final file = state.files[fileIndex];
                  return _FileTile(
                    key: ValueKey('file-${file.id}'),
                    file: file,
                    onTap: () => _openFile(file, state.files, fileIndex),
                    onLongPress: () => _showFileActions(file),
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
                  ElevatedButton(onPressed: _refresh, child: const Text('再試行')),
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

class _FolderTile extends StatelessWidget {
  final DriveFolder folder;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FolderTile({
    super.key,
    required this.folder,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
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

class _FileTile extends StatelessWidget {
  final Attachment file;
  final VoidCallback onTap;

  final VoidCallback? onLongPress;

  const _FileTile({
    super.key,
    required this.file,
    required this.onTap,
    this.onLongPress,
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
      onLongPress: onLongPress,
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
