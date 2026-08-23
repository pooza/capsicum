import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/drive_provider.dart';
import '../util/drive_error.dart';
import '../util/op_error.dart';
import '../widget/desktop_menu_model.dart';
import '../widget/retry_error_view.dart';
import '../widget/screen_menu.dart';
import 'media_viewer_screen.dart';

class DriveManagerScreen extends ConsumerStatefulWidget {
  const DriveManagerScreen({super.key});

  @override
  ConsumerState<DriveManagerScreen> createState() => _DriveManagerScreenState();
}

class _DriveManagerScreenState extends ConsumerState<DriveManagerScreen> {
  final _scrollController = ScrollController();
  final List<_FolderEntry> _folderStack = [];
  bool _isDragging = false;

  /// ドラッグ中に viewport 端へ近づいたとき GridView を自動スクロールさせる
  /// (#693)。ReorderableListView 内部と同じ公式クラスを使い、ドラッグ開始時に
  /// 生成・終了時に破棄する。
  EdgeDraggingAutoScroller? _dragAutoScroller;
  // 自動 loadMore (#452) の post-frame callback を毎フレーム積むのを避ける
  // ためのラッチ (#459)。folder 移動 / refresh で false に戻す。
  bool _autoLoadRequested = false;

  /// 複数ファイル選択モード (#567)。v1 は現フォルダ内のファイルのみ対象とし、
  /// フォルダの一括移動・フォルダ間の横断選択は範囲外。
  bool _selectionMode = false;
  final Set<String> _selectedFileIds = {};

  /// 一括移動の二重実行ガード。フォルダピッカー表示中・移動 API 呼び出し中
  /// に IconButton が再タップされた場合、await 中に同じ N 件をもう一度
  /// move する事故を防ぐ。
  bool _bulkMoving = false;

  String? get _currentFolderId =>
      _folderStack.isEmpty ? null : _folderStack.last.id;

  String get _currentTitle =>
      _folderStack.isEmpty ? 'ドライブ' : _folderStack.last.name;

  /// 1 つ上のフォルダ ID（ルート直下なら null）。AppBar 左への drop で親へ移す
  /// 際に使う (#694 で単体／一括の両 drop が参照)。
  String? get _parentFolderId => _folderStack.length >= 2
      ? _folderStack[_folderStack.length - 2].id
      : null;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _stopDragAutoScroll();
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

  /// 取得済みコンテンツが viewport に収まりきってスクロールが発生しない場合、
  /// 自動再試行のフックがないため自前で次ページを要求する (#452)。
  /// hasMore / isLoadingMore / loadMoreError で無限ループを防ぐ。state 側の
  /// 予条件判定は [shouldAutoLoadMore] にまとめて回帰テスト可能にしてある
  /// (#456)。
  void _maybeLoadMoreIfNotScrollable() {
    if (!mounted || !_scrollController.hasClients) return;
    if (_scrollController.position.maxScrollExtent > 0) return;
    final state = ref.read(driveContentsProvider(_currentFolderId)).valueOrNull;
    if (!shouldAutoLoadMore(state)) return;
    ref.read(driveContentsProvider(_currentFolderId).notifier).loadMore();
  }

  /// ドラッグ開始時に呼ぶ。[itemContext] はドラッグ元タイルの context
  /// （GridView の Scrollable 配下にあるため [Scrollable.of] が届く）。
  /// velocityScalar は既定 (7) だと長いリストで届くまでが遅いため、
  /// ReorderableListView が使う 50 に合わせる。
  void _startDragAutoScroll(BuildContext itemContext) {
    _dragAutoScroller = EdgeDraggingAutoScroller(
      Scrollable.of(itemContext),
      velocityScalar: 50,
    );
  }

  /// ドラッグ位置の更新ごとに呼ぶ。指の位置を中心にした feedback 相当の
  /// 矩形 (グローバル座標) を渡し、viewport 端に近ければスクロールが始まり
  /// 離れれば止まる。矩形が静止していてもスクロール継続は scroller 側が
  /// 面倒を見る。
  void _updateDragAutoScroll(Offset globalPosition) {
    _dragAutoScroller?.startAutoScrollIfNecessary(
      Rect.fromCenter(center: globalPosition, width: 80, height: 80),
    );
  }

  void _stopDragAutoScroll() {
    _dragAutoScroller?.stopAutoScroll();
    _dragAutoScroller = null;
  }

  void _openFolder(DriveFolder folder) {
    setState(() {
      _folderStack.add(_FolderEntry(id: folder.id, name: folder.name));
      _autoLoadRequested = false;
    });
  }

  void _goBack() {
    if (_folderStack.isNotEmpty) {
      setState(() {
        _folderStack.removeLast();
        _autoLoadRequested = false;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  void _refresh() {
    ref.invalidate(driveContentsProvider(_currentFolderId));
    setState(() {
      _autoLoadRequested = false;
    });
  }

  DriveSupport? get _drive {
    final adapter = ref.read(currentAdapterProvider);
    return adapter is DriveSupport ? adapter as DriveSupport : null;
  }

  /// 移動先フォルダ選択ダイアログを開き、結果を返す。`_FolderPick(id: null)`
  /// がルート、`_FolderPick(id: <非null>)` が特定フォルダ、`null` の戻りは
  /// キャンセル (tap outside or キャンセルボタン)。
  ///
  /// 候補は現在地ベース (#693): 親フォルダ (一段上へ戻す。深さ 1 ならルート)
  /// + 現在フォルダ直下の子フォルダ (一段下へ入れる)。ブラウズと同じ感覚で
  /// 一段ずつ運び、任意階層へは移動の繰り返しで到達する。親へ戻す導線の
  /// 考え方は既存のドラッグ&ドロップ (AppBar 左の DragTarget) と揃えている。
  Future<_FolderPick?> _showFolderPickerDialog({
    required String title,
    String? excludeFolderId,
  }) async {
    // limit 省略時の Misskey 既定は 10 で、フォルダが多いと候補が黙って
    // 切れるため API 上限の 100 まで広げる (ダイアログはページングしない)。
    final folders =
        await _drive?.getDriveFolders(
          folderId: _currentFolderId,
          query: const TimelineQuery(limit: 100),
        ) ??
        const [];
    if (!mounted) return null;
    // 親フォルダ候補。ルートにいるときは「上」が無いので出さない。深さ 1 の
    // ときの親はルート (/)。
    final hasParent = _folderStack.isNotEmpty;
    final parent = _folderStack.length >= 2
        ? _folderStack[_folderStack.length - 2]
        : null;
    final children = folders.where((f) => f.id != excludeFolderId).toList();
    return showDialog<_FolderPick>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: double.maxFinite,
            child: !hasParent && children.isEmpty
                ? const Text('移動できるフォルダがありません')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      if (hasParent) ...[
                        ListTile(
                          leading: Icon(
                            parent == null
                                ? Icons.home_outlined
                                : Icons.drive_folder_upload_outlined,
                          ),
                          title: Text(parent?.name ?? 'ルート (/)'),
                          subtitle: const Text('上の階層'),
                          onTap: () => Navigator.pop(
                            dialogContext,
                            _FolderPick(parent?.id),
                          ),
                        ),
                        if (children.isNotEmpty) const Divider(height: 1),
                      ],
                      for (final f in children)
                        ListTile(
                          leading: const Icon(Icons.folder),
                          title: Text(f.name),
                          onTap: () =>
                              Navigator.pop(dialogContext, _FolderPick(f.id)),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('キャンセル'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _promptMoveFile(Attachment file) async {
    final picked = await _showFolderPickerDialog(title: 'ファイルの移動先');
    if (picked == null) return; // キャンセル
    await _moveFileToFolder(file, picked.id);
  }

  Future<void> _promptMoveFolder(DriveFolder folder) async {
    final picked = await _showFolderPickerDialog(
      title: 'フォルダの移動先',
      excludeFolderId: folder.id,
    );
    if (picked == null) return; // キャンセル
    final destParentId = picked.id;
    if (destParentId == folder.parentId) return; // 変更なし
    try {
      await _drive?.moveDriveFolder(folder.id, destParentId);
      // 現在フォルダから出ていったので一覧から除外。
      ref
          .read(driveContentsProvider(_currentFolderId).notifier)
          .removeFolder(folder.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('フォルダを移動しました')));
      }
    } catch (e, st) {
      reportDriveOpFailure(
        'move_folder',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移動に失敗しました (${summarizeOpError(e)})')),
        );
      }
    }
  }

  void _enterSelectionMode() {
    setState(() {
      _selectionMode = true;
      _selectedFileIds.clear();
    });
  }

  void _exitSelectionMode() {
    // #694 の一括 D&D は fire-and-forget で _moveSelectedFilesToFolder →
    // _exitSelectionMode に至るため、移動の await 中に画面を離れると dispose 済み
    // State で setState する事故が起きうる。mounted ガードで防ぐ（AppBar の
    // 同期呼び出しでは常に mounted なので無害）。
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedFileIds.clear();
    });
  }

  void _toggleFileSelected(String id) {
    setState(() {
      if (!_selectedFileIds.remove(id)) {
        _selectedFileIds.add(id);
      }
    });
  }

  Future<void> _promptMoveSelectedFiles() async {
    if (_selectedFileIds.isEmpty) return;
    if (_bulkMoving) return;
    _bulkMoving = true;
    try {
      final picked = await _showFolderPickerDialog(
        title: '${_selectedFileIds.length} 件のファイルの移動先',
      );
      if (picked == null) return;
      await _moveSelectedFilesToFolder(picked.id);
    } finally {
      // unmount 後でも内部フラグだけ無条件に降ろす。setState を伴わないので
      // dispose 済み State でも安全 (2 回目レビュー追従)。
      _bulkMoving = false;
    }
  }

  /// 一括移動 (#567)。エラーは件ごとに握り、最終 SnackBar で N/M 件成功を出す。
  /// 移動先 == 現在のフォルダなら #563 と同様 no-op。
  Future<void> _moveSelectedFilesToFolder(String? folderId) async {
    if (folderId == _currentFolderId) {
      _exitSelectionMode();
      return;
    }
    final ids = _selectedFileIds.toList();
    final notifier = ref.read(driveContentsProvider(_currentFolderId).notifier);
    var success = 0;
    Object? lastError;
    StackTrace? lastSt;
    for (final id in ids) {
      try {
        await _drive?.moveDriveFile(id, folderId);
        notifier.moveFileOut(id);
        success++;
      } catch (e, st) {
        lastError = e;
        lastSt = st;
      }
    }
    if (lastError != null && lastSt != null) {
      reportDriveOpFailure(
        'move_files_bulk',
        lastError,
        lastSt,
        account: ref.read(currentAccountProvider),
      );
    }
    if (mounted) {
      final msg = lastError == null
          ? '$success 件のファイルを移動しました'
          : '$success / ${ids.length} 件移動しました (${summarizeOpError(lastError)})';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    _exitSelectionMode();
  }

  /// ドラッグ&ドロップの移動先確定 (#694)。ペイロードは `List<Attachment>` に
  /// 統一してある（単体ドラッグは要素 1）。選択モード中のドラッグは選択全件を
  /// 運ぶので、既存の一括移動 [_moveSelectedFilesToFolder]（`_selectedFileIds`
  /// 基準・移動後に選択解除）を再利用する。通常ドラッグは単体移動。
  Future<void> _handleDropToFolder(
    List<Attachment> files,
    String? folderId,
  ) async {
    if (_selectionMode) {
      // 一括移動は fire-and-forget（DragTarget は戻り Future を捨てる）。移動完了
      // まで選択は解除されないため、完了前に同じ選択を再ドロップすると二重移動に
      // なりうる。ダイアログ経路と同じ _bulkMoving で再入を防ぐ。
      if (_bulkMoving) return;
      _bulkMoving = true;
      try {
        await _moveSelectedFilesToFolder(folderId);
      } finally {
        _bulkMoving = false;
      }
      return;
    }
    if (files.isEmpty) return;
    await _moveFileToFolder(files.first, folderId);
  }

  /// 選択モード中の一括ドラッグ用フィードバック (#694)。代表サムネに選択枚数の
  /// バッジを重ねる。
  Widget _buildBulkDragFeedback(Attachment file) {
    final theme = Theme.of(context);
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 80,
        height: 80,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(
              opacity: 0.8,
              child: _FileTile(file: file, onTap: () {}),
            ),
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${_selectedFileIds.length}',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _moveFileToFolder(Attachment file, String? folderId) async {
    // 移動先 == 現在のフォルダなら API も notifier も触らない (#563)。
    // moveFileOut を呼ぶとローカルリストから消えるが API は no-op のため、
    // 手動 refresh まで表示が戻らない事故が起きていた。
    if (folderId == _currentFolderId) return;
    try {
      await _drive?.moveDriveFile(file.id, folderId);
      ref
          .read(driveContentsProvider(_currentFolderId).notifier)
          .moveFileOut(file.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ファイルを移動しました')));
      }
    } catch (e, st) {
      reportDriveOpFailure(
        'move_file_out',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移動に失敗しました (${summarizeOpError(e)})')),
        );
      }
    }
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
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移動'),
              onTap: () {
                Navigator.pop(sheetContext);
                _promptMoveFile(file);
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
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移動'),
              onTap: () {
                Navigator.pop(sheetContext);
                _promptMoveFolder(folder);
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
    String hint, {
    int? maxLength,
  }) async {
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
            maxLength: maxLength,
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
      // ⚠ **client で止める (#1012)。**超えるとサーバーが断り、画面には
      // 「操作に失敗しました」しか出ない。根拠は
      // [InputLimits.attachmentDescription]。
      maxLength: InputLimits.attachmentDescription,
    );
    if (newAlt == null) return;
    try {
      final adapter = ref.read(currentAdapterProvider);
      if (adapter is! DriveSupport) return;
      final misskeyAdapter = adapter as dynamic;
      if (newAlt.isEmpty) {
        // ⚠ **消去は空文字ではなく明示的な null (#1005 / #1012)。**
        // `updateDriveFile` は null をキーごと省略するので、空文字のまま渡すと
        // body が `{fileId}` だけになり Misskey 側で更新対象が空になって 500。
        // 仮に通っても省略は「変更なし」なので ALT を消せない。
        // ⚠ **投稿側 (`MisskeyAdapter.updateAttachmentDescription`) は #1005 で
        // 分けたのに、ここだけ空文字のままだった。**消去の表現が null と `''`
        // の 2 種類に割れていたので、client の消去用メソッドへ寄せる。
        await misskeyAdapter.client.clearDriveFileComment(file.id);
      } else {
        await misskeyAdapter.client.updateDriveFile(file.id, comment: newAlt);
      }
      ref
          .read(driveContentsProvider(_currentFolderId).notifier)
          .updateFileDescription(file.id, newAlt);
    } catch (e, st) {
      reportDriveOpFailure(
        'edit_alt',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作に失敗しました (${summarizeOpError(e)})')),
        );
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
    } catch (e, st) {
      reportDriveOpFailure(
        'rename_file',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作に失敗しました (${summarizeOpError(e)})')),
        );
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
    } catch (e, st) {
      reportDriveOpFailure(
        'delete_file',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除に失敗しました (${summarizeOpError(e)})')),
        );
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
    } catch (e, st) {
      reportDriveOpFailure(
        'rename_folder',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作に失敗しました (${summarizeOpError(e)})')),
        );
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
    } catch (e, st) {
      reportDriveOpFailure(
        'delete_folder',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作に失敗しました (${summarizeOpError(e)})')),
        );
      }
    }
  }

  Future<void> _createFolder() async {
    final name = await _showTextInputDialog('フォルダを作成', '', 'フォルダ名');
    if (name == null || name.isEmpty) return;
    try {
      await _drive?.createDriveFolder(name, parentId: _currentFolderId);
      _refresh();
    } catch (e, st) {
      reportDriveOpFailure(
        'create_folder',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作に失敗しました (${summarizeOpError(e)})')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final drive = ref.watch(driveContentsProvider(_currentFolderId));

    // loadMore 失敗を SnackBar でユーザーに 1 回だけ通知する (#430)。
    // 失敗中はスクロール由来の自動再試行が抑止されるため、ユーザーは
    // pull-to-refresh で明示的に再読み込みする必要がある。
    ref.listen(driveContentsProvider(_currentFolderId), (prev, next) {
      final error = next.valueOrNull?.loadMoreError;
      if (error != null && prev?.valueOrNull?.loadMoreError == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('読み込みに失敗しました。下に引いて再読み込みしてください'),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    });

    return ScreenMenu(
      label: 'ドライブ',
      // コールバックは**名前付きメソッドのテアオフ**で渡す (#835)。その場で作った
      // 無名関数はビルドのたびに別物になり、[MenuActionEntry] の値等価が崩れて
      // メニューバー全体が作り直される。
      entries: buildDriveMenuEntries(
        canGoUp: _folderStack.isNotEmpty,
        selectionMode: _selectionMode,
        hasSelection: _selectedFileIds.isNotEmpty,
        onGoUp: _goBack,
        onRefresh: _refresh,
        onCreateFolder: _createFolder,
        onEnterSelectionMode: _enterSelectionMode,
        onExitSelectionMode: _exitSelectionMode,
        onMoveSelected: _promptMoveSelectedFiles,
      ),
      child: _buildScaffold(context, drive),
    );
  }

  Widget _buildScaffold(BuildContext context, AsyncValue<DriveState> drive) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: _folderStack.isEmpty && !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          _exitSelectionMode();
        } else {
          _goBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: _selectionMode
              ? Text('${_selectedFileIds.length} 件選択中')
              : (_isDragging && _folderStack.isNotEmpty
                    ? Text(
                        '← 親フォルダへ移動',
                        style: TextStyle(color: theme.colorScheme.primary),
                      )
                    : Text(_currentTitle)),
          backgroundColor: theme.colorScheme.inversePrimary,
          leading: _selectionMode
              ? (_folderStack.isEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '選択を解除',
                        onPressed: _exitSelectionMode,
                      )
                    // 選択モード中でも親フォルダへの一括 drop を受ける (#694)。
                    // タップは従来どおり選択解除。ドラッグ中／drop 候補時は
                    // arrow_back に変えて「ここに落とすと親へ」を示す。
                    : DragTarget<List<Attachment>>(
                        onWillAcceptWithDetails: (_) => true,
                        onAcceptWithDetails: (details) =>
                            _handleDropToFolder(details.data, _parentFolderId),
                        builder: (context, candidateData, _) => IconButton(
                          icon: Icon(
                            _isDragging || candidateData.isNotEmpty
                                ? Icons.arrow_back
                                : Icons.close,
                            color: candidateData.isNotEmpty
                                ? theme.colorScheme.primary
                                : null,
                          ),
                          tooltip: candidateData.isNotEmpty
                              ? '親フォルダへ移動'
                              : '選択を解除',
                          onPressed: _exitSelectionMode,
                        ),
                      ))
              : (_folderStack.isEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: _goBack,
                      )
                    : DragTarget<List<Attachment>>(
                        onWillAcceptWithDetails: (_) => true,
                        onAcceptWithDetails: (details) =>
                            _handleDropToFolder(details.data, _parentFolderId),
                        builder: (context, candidateData, _) => IconButton(
                          icon: Icon(
                            Icons.arrow_back,
                            color: candidateData.isNotEmpty || _isDragging
                                ? theme.colorScheme.primary
                                : null,
                          ),
                          onPressed: _goBack,
                        ),
                      )),
          actions: _selectionMode
              ? [
                  IconButton(
                    icon: const Icon(Icons.drive_file_move_outline),
                    tooltip: '移動',
                    onPressed: _selectedFileIds.isEmpty
                        ? null
                        : _promptMoveSelectedFiles,
                  ),
                ]
              : [
                  IconButton(
                    icon: const Icon(Icons.checklist),
                    tooltip: '複数選択',
                    onPressed: _enterSelectionMode,
                  ),
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

            // 画面幅が広いと初期 20 件が viewport 内に収まり、スクロール
            // 由来の loadMore() が起動しない。レイアウト確定後にスクロール
            // 可能か再評価し、必要なら次ページを要求する (#452)。
            // 毎フレーム積むのを避けるため _autoLoadRequested ラッチで
            // 一度だけ実行する。folder 移動 / refresh で false に戻す (#459)。
            if (!_autoLoadRequested) {
              _autoLoadRequested = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                // ref.read が dispose 後に呼ばれる極稀ケース等に備え、全体を
                // try/catch で包み Sentry に上げる (#459)。
                try {
                  _maybeLoadMoreIfNotScrollable();
                } catch (e, st) {
                  reportDriveOpFailure(
                    'auto_load',
                    e,
                    st,
                    account: ref.read(currentAccountProvider),
                  );
                }
              });
            }

            if (totalFolders == 0 && totalFiles == 0) {
              return const Center(child: Text('ファイルがありません'));
            }

            return RefreshIndicator(
              onRefresh: () =>
                  ref.refresh(driveContentsProvider(_currentFolderId).future),
              child: GridView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(4),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 140,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemCount: totalItems,
                itemBuilder: (context, index) {
                  if (index < totalFolders) {
                    final folder = state.folders[index];
                    // 選択モード中もフォルダは drop 先として活かす (#694 一括移動)。
                    // タップ／ロングプレス（開く・操作メニュー）は選択モード中は
                    // 無効（フォルダ複数選択は範囲外、#567）。
                    return DragTarget<List<Attachment>>(
                      key: ValueKey('folder-${folder.id}'),
                      onWillAcceptWithDetails: (_) => true,
                      onAcceptWithDetails: (details) =>
                          _handleDropToFolder(details.data, folder.id),
                      builder: (context, candidateData, rejectedData) {
                        return _FolderTile(
                          folder: folder,
                          onTap: _selectionMode
                              ? () {}
                              : () => _openFolder(folder),
                          onLongPress: _selectionMode
                              ? () {}
                              : () => _showFolderActions(folder),
                          isHighlighted: candidateData.isNotEmpty,
                        );
                      },
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
                  if (_selectionMode) {
                    final isSelected = _selectedFileIds.contains(file.id);
                    // 未選択タイルは従来どおり tap で選択トグル（drag は起こさない）。
                    if (!isSelected) {
                      return _FileTile(
                        key: ValueKey('file-${file.id}'),
                        file: file,
                        isSelectionMode: true,
                        isSelected: false,
                        onTap: () => _toggleFileSelected(file.id),
                      );
                    }
                    // 選択済みタイルは long-press で「選択全件」をまとめてドラッグ
                    // できる (#694)。drop 先（フォルダ／親）の DragTarget は選択全件を
                    // _handleDropToFolder → _moveSelectedFilesToFolder で移す。
                    final selected = state.files
                        .where((f) => _selectedFileIds.contains(f.id))
                        .toList();
                    final tile = _FileTile(
                      file: file,
                      isSelectionMode: true,
                      isSelected: true,
                      onTap: () => _toggleFileSelected(file.id),
                    );
                    return LongPressDraggable<List<Attachment>>(
                      key: ValueKey('file-${file.id}'),
                      data: selected,
                      onDragStarted: () {
                        setState(() => _isDragging = true);
                        _startDragAutoScroll(context);
                      },
                      onDragUpdate: (details) =>
                          _updateDragAutoScroll(details.globalPosition),
                      onDragEnd: (_) {
                        setState(() => _isDragging = false);
                        _stopDragAutoScroll();
                      },
                      feedback: _buildBulkDragFeedback(file),
                      childWhenDragging: Opacity(opacity: 0.3, child: tile),
                      // 起点以外の選択タイルもドラッグ中はまとめて減光する (#694)。
                      child: Opacity(
                        opacity: _isDragging ? 0.3 : 1.0,
                        child: tile,
                      ),
                    );
                  }
                  return LongPressDraggable<List<Attachment>>(
                    key: ValueKey('file-${file.id}'),
                    data: [file],
                    onDragStarted: () {
                      setState(() => _isDragging = true);
                      _startDragAutoScroll(context);
                    },
                    onDragUpdate: (details) =>
                        _updateDragAutoScroll(details.globalPosition),
                    onDragEnd: (_) {
                      setState(() => _isDragging = false);
                      _stopDragAutoScroll();
                    },
                    feedback: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 80,
                        height: 80,
                        child: Opacity(
                          opacity: 0.8,
                          child: _FileTile(file: file, onTap: () {}),
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.3,
                      child: _FileTile(file: file, onTap: () {}),
                    ),
                    child: _FileTile(
                      file: file,
                      onTap: () => _openFile(file, state.files, fileIndex),
                      onMorePressed: () => _showFileActions(file),
                    ),
                  );
                },
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => RetryErrorView(
            message: '読み込みに失敗しました',
            isRetrying: drive.isLoading,
            onRetry: _refresh,
          ),
        ),
      ),
    );
  }
}

/// ドライブ画面のデスクトップメニュー項目 (#939)。
///
/// この画面は AppBar に実操作が揃っているので、そこにあるものをそのまま写す。
/// **出し分けの条件は AppBar 側と同一にする**（#835）——「使えない操作をメニュー
/// にだけ見せない」ため。項目を消すのではなく**無効化して残す**のはスレッド画面
/// （`buildThreadMenuEntries`）と同じ判断で、項目が消えると場所が動いて探しにくい
/// ため。この画面は選択モードで AppBar の actions が丸ごと入れ替わるので、消す方を
/// 採ると 3 項目が入れ替わり立ち替わりして特に読みにくい。
///
/// ⚠ 「上の階層へ」は [canGoUp] が false のとき無効にする。AppBar の leading は
/// 同じ [onGoUp] を常に出しているが、ルートに居るときのそれは **× で画面を閉じる**
/// 操作であって「上の階層へ」ではない。メニューでは行き先のラベルを名乗る以上、
/// 上が無ければ押せてはいけない。
///
/// ⚠ **[selectionMode] のときも「上の階層へ」を無効にする** (#984)。同じ理由で、
/// 選択モード中の戻る操作は `PopScope` の `onPopInvokedWithResult` が
/// `_exitSelectionMode()` へ振り分けており、**上の階層へは行かない**。ここだけ
/// 素通しにすると、選択を抱えたまま親フォルダへ移動でき、`hasSelection` が
/// true のままなので **いま見えていないファイルを、別のフォルダを基準にした
/// 移動先ピッカーで動かせてしまう**。
///
/// ⚠ **選択を解除してから移動する案は採らない。** 「上の階層へ」を選んだだけで
/// 選択が消えるのは、メニューの他項目が選択を保つのと非対称になる。#835 の
/// 「使えない操作は無効化して残す」に従って押せなくする方が揃う。
///
/// ダイアログを開く項目に付く `…` は既存メニューの表記（`絵文字…` / `予約投稿…`）
/// に揃えたもの。issue の項目表では「フォルダを作成」だが、`移動…` と同じく
/// ダイアログを開くので同じ menu 内で表記が割れないよう `…` を付けている。
///
/// ファイル / フォルダ単位の操作（リネーム・削除・ALT 編集等）は載せていない。
/// 「どの対象への操作か」を指す口が無く、選択という概念を持つこの画面なら書ける
/// が、上の 6 項目が入って動いてから別途判断する（#939 本文）。
///
/// コールバックを引数で受けるのは、画面全体を pump せずに項目の出し分けを試験
/// できるようにするため（条件が 3 つの bool で表せるので切り出せる。基準は
/// `desktop_menu_model.dart` の「画面メニュー貢献のテストの流儀」#960）。
@visibleForTesting
List<MenuEntry> buildDriveMenuEntries({
  required bool canGoUp,
  required bool selectionMode,
  required bool hasSelection,
  required VoidCallback onGoUp,
  required VoidCallback onRefresh,
  required VoidCallback onCreateFolder,
  required VoidCallback onEnterSelectionMode,
  required VoidCallback onExitSelectionMode,
  required VoidCallback onMoveSelected,
}) => [
  MenuActionEntry(
    label: '上の階層へ',
    icon: Icons.drive_folder_upload_outlined,
    onSelected: canGoUp && !selectionMode ? onGoUp : null,
  ),
  MenuActionEntry(label: '再読み込み', icon: Icons.refresh, onSelected: onRefresh),
  const MenuGroupSeparator(),
  MenuActionEntry(
    label: 'フォルダを作成…',
    icon: Icons.create_new_folder_outlined,
    onSelected: selectionMode ? null : onCreateFolder,
  ),
  const MenuGroupSeparator(),
  MenuActionEntry(
    label: '複数選択',
    icon: Icons.checklist,
    onSelected: selectionMode ? null : onEnterSelectionMode,
  ),
  MenuActionEntry(
    label: '選択を解除',
    icon: Icons.close,
    onSelected: selectionMode ? onExitSelectionMode : null,
  ),
  MenuActionEntry(
    label: '移動…',
    icon: Icons.drive_file_move_outline,
    onSelected: selectionMode && hasSelection ? onMoveSelected : null,
  ),
];

class _FolderEntry {
  final String id;
  final String name;
  const _FolderEntry({required this.id, required this.name});
}

/// 移動先選択ダイアログの戻り値。`id == null` がルート、それ以外は対象
/// フォルダ ID (#437)。ダイアログ全体の `null` 戻りはキャンセルを意味する
/// ため、root pick と区別するために wrapper 化している。
class _FolderPick {
  final String? id;
  const _FolderPick(this.id);
}

class _FolderTile extends StatelessWidget {
  final DriveFolder folder;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool isHighlighted;

  const _FolderTile({
    required this.folder,
    required this.onTap,
    required this.onLongPress,
    this.isHighlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: isHighlighted
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          border: isHighlighted
              ? Border.all(color: theme.colorScheme.primary, width: 2)
              : null,
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
  final VoidCallback? onMorePressed;

  /// 選択モード中なら true。選択状態は [isSelected] で別途渡す (#567)。
  final bool isSelectionMode;
  final bool isSelected;

  const _FileTile({
    super.key,
    required this.file,
    required this.onTap,
    this.onMorePressed,
    this.isSelectionMode = false,
    this.isSelected = false,
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
          if (!isSelectionMode && onMorePressed != null)
            Positioned(
              top: 2,
              right: 2,
              child: GestureDetector(
                onTap: onMorePressed,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.more_horiz,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          // 選択モード時のオーバーレイ (#567)。選択中はチェック、未選択は枠のみ。
          if (isSelectionMode) ...[
            if (isSelected)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: theme.colorScheme.primary,
                      width: 2,
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 2,
              right: 2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isSelected ? Icons.check : Icons.radio_button_unchecked,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
