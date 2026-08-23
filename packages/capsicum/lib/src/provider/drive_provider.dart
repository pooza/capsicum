import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../util/exception_scrub.dart';
import 'account_manager_provider.dart';
import 'timeline_provider.dart' show loadMoreMaxRetries, loadMoreRetryDelay;

/// `null` 自体が「明示的にクリア」を意味する nullable フィールドを
/// `copyWith` で保持／差し替えするための sentinel。
const Object _keepLoadMoreError = Object();

class DriveState {
  final List<DriveFolder> folders;
  final List<Attachment> files;
  final bool isLoadingMore;
  final bool hasMore;

  /// 直近の [DriveContentsNotifier.loadMore] が最終的に失敗した場合の例外。
  /// 成功時は null。スクロール由来の自動再試行を抑止する番兵として使うため、
  /// pull-to-refresh 等で build() が再実行されるまでクリアされない。
  final Object? loadMoreError;

  const DriveState({
    this.folders = const [],
    this.files = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
    this.loadMoreError,
  });

  /// [loadMoreError] は引数省略時に現状を保持する。明示的に `null` を渡した
  /// 場合はクリア、例外を渡した場合は差し替え、という三状態を区別する。
  DriveState copyWith({
    List<DriveFolder>? folders,
    List<Attachment>? files,
    bool? isLoadingMore,
    bool? hasMore,
    Object? loadMoreError = _keepLoadMoreError,
  }) {
    return DriveState(
      folders: folders ?? this.folders,
      files: files ?? this.files,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      loadMoreError: identical(loadMoreError, _keepLoadMoreError)
          ? this.loadMoreError
          : loadMoreError,
    );
  }
}

/// drive_manager_screen の post-frame 自動 loadMore (#452 / #459) が
/// `loadMore()` を呼んでよい条件 (DriveState 側の予条件のみ)。
/// scroll controller 側の `maxScrollExtent > 0` チェックは widget 側で
/// 持つ。本関数はそれ以外の純粋条件を 1 ヶ所に集めて回帰テスト可能にした
/// (#456)。
///
/// 発火条件:
/// - state が AsyncData として確定している (= null でない)
/// - `hasMore == true`
/// - `isLoadingMore == false`
/// - `loadMoreError == null` (sentinel パターンで残っている前回失敗を尊重)
bool shouldAutoLoadMore(DriveState? state) {
  if (state == null) return false;
  if (!state.hasMore) return false;
  if (state.isLoadingMore) return false;
  if (state.loadMoreError != null) return false;
  return true;
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
    try {
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
    } catch (e, st) {
      try {
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          hint: Hint.withMap({'folderId': arg ?? 'root'}),
        );
      } catch (_) {
        // Sentry failure must not block the AsyncError path.
      }
      rethrow;
    }
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

  void moveFileOut(String fileId) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        files: current.files.where((f) => f.id != fileId).toList(),
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
    // 直前の loadMore が失敗している場合、スクロール由来の自動再試行は抑止する。
    // pull-to-refresh で build() が再実行されるまで loadMoreError は残るため、
    // ユーザーが明示的に refresh するまでロックされる (#430)。
    if (current.loadMoreError != null) return;

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
            loadMoreError: null,
          ),
        );
        return;
      } catch (e, st) {
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        try {
          final failedMaxId = current.files.lastOrNull?.id;
          Sentry.captureException(
            scrubException(e),
            stackTrace: st,
            hint: Hint.withMap({
              'folderId': arg ?? 'root',
              'maxId': failedMaxId ?? 'null',
              'attempts': '${attempt + 1}',
            }),
          );
        } catch (_) {
          // Sentry failure must not block state recovery.
        }
        final latest = state.valueOrNull ?? current;
        state = AsyncData(
          latest.copyWith(isLoadingMore: false, loadMoreError: e),
        );
      }
    }
  }
}

final driveContentsProvider = AsyncNotifierProvider.autoDispose
    .family<DriveContentsNotifier, DriveState, String?>(
      DriveContentsNotifier.new,
    );
