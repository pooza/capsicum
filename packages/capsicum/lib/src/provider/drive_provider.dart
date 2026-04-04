import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart' show loadMoreMaxRetries, loadMoreRetryDelay;

class DriveState {
  final List<DriveFolder> folders;
  final List<Attachment> files;
  final bool isLoadingMore;
  final bool hasMore;

  const DriveState({
    this.folders = const [],
    this.files = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
  });

  DriveState copyWith({
    List<DriveFolder>? folders,
    List<Attachment>? files,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return DriveState(
      folders: folders ?? this.folders,
      files: files ?? this.files,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

/// Drive contents for a given folder (null = root).
class DriveContentsNotifier
    extends AutoDisposeFamilyAsyncNotifier<DriveState, String?> {
  static const _pageSize = 20;

  @override
  Future<DriveState> build(String? arg) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! DriveSupport) {
      return const DriveState(hasMore: false);
    }

    final drive = adapter as DriveSupport;
    final folders = await drive.getDriveFolders(folderId: arg);
    final files = await drive.getDriveFiles(
      folderId: arg,
      query: const TimelineQuery(limit: _pageSize),
    );
    return DriveState(
      folders: folders,
      files: files,
      hasMore: files.length >= _pageSize,
    );
  }

  void removeFile(String fileId) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        files: current.files.where((f) => f.id != fileId).toList(),
      ),
    );
  }

  void renameFile(String fileId, String newName) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        files: current.files
            .map(
              (f) => f.id == fileId
                  ? Attachment(
                      id: f.id,
                      type: f.type,
                      url: f.url,
                      previewUrl: f.previewUrl,
                      description: f.description,
                      name: newName,
                    )
                  : f,
            )
            .toList(),
      ),
    );
  }

  void updateFileDescription(String fileId, String description) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        files: current.files
            .map(
              (f) => f.id == fileId
                  ? Attachment(
                      id: f.id,
                      type: f.type,
                      url: f.url,
                      previewUrl: f.previewUrl,
                      description: description.isEmpty ? null : description,
                      name: f.name,
                    )
                  : f,
            )
            .toList(),
      ),
    );
  }

  void renameFolder(String folderId, String newName) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        folders: current.folders
            .map(
              (f) => f.id == folderId
                  ? DriveFolder(id: f.id, name: newName, parentId: f.parentId)
                  : f,
            )
            .toList(),
      ),
    );
  }

  void removeFolder(String folderId) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        folders: current.folders.where((f) => f.id != folderId).toList(),
      ),
    );
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! DriveSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.files.last.id;
        final older = await (adapter as DriveSupport).getDriveFiles(
          folderId: arg,
          query: TimelineQuery(maxId: lastId, limit: _pageSize),
        );

        state = AsyncData(
          base.copyWith(
            files: [...base.files, ...older],
            isLoadingMore: false,
            hasMore: older.length >= _pageSize,
          ),
        );
        return;
      } catch (_) {
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(isLoadingMore: false),
        );
      }
    }
  }
}

final driveContentsProvider = AsyncNotifierProvider.autoDispose
    .family<DriveContentsNotifier, DriveState, String?>(
      DriveContentsNotifier.new,
    );
