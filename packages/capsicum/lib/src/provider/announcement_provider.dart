import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/sentry_op_failure.dart';
import 'account_manager_provider.dart';

/// Announcement list state.
class AnnouncementState {
  final List<Announcement> announcements;

  const AnnouncementState({this.announcements = const []});

  AnnouncementState copyWith({List<Announcement>? announcements}) =>
      AnnouncementState(announcements: announcements ?? this.announcements);
}

/// Notifier that manages announcement fetching and dismissal.
class AnnouncementNotifier extends AutoDisposeAsyncNotifier<AnnouncementState> {
  /// 破棄済みか (#888)。[refresh] は画面の外（ライフサイクル / streaming）から
  /// 呼ばれるため、await 中に破棄されていたら state を触らない。`ref.onDispose`
  /// は再計算のたびにも走るので、build() の先頭で false へ戻す。
  bool _disposed = false;

  @override
  Future<AnnouncementState> build() async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! AnnouncementSupport) {
      return const AnnouncementState();
    }

    final announcements = await (adapter as AnnouncementSupport)
        .getAnnouncements();

    return AnnouncementState(announcements: announcements);
  }

  /// お知らせを取り直して差し替える (#888)。
  ///
  /// `invalidate` と違ってローディングに落とさないので、表示中の一覧が一瞬
  /// 消えることがない。新しいお知らせが**アカウントを切り替えるまで反映され
  /// ない**問題に対して、ポーリング（常駐タイマー）を持たずに次の 3 つの機会で
  /// 取り直すために使う:
  ///
  /// - フォアグラウンド復帰（モバイルで背面に回っていた間の新着）
  /// - お知らせ画面 / タブを開いたとき
  /// - streaming の announcement イベント受信（デスクトップは前面に居続ける
  ///   ので復帰の機会が無く、これが主経路になる）
  ///
  /// 失敗は握り潰す（お知らせは補助的な情報で、失敗時は現状維持でよい）。
  Future<void> refresh() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! AnnouncementSupport) return;
    try {
      final announcements = await (adapter as AnnouncementSupport)
          .getAnnouncements();
      if (_disposed) return;
      // 往復の間にアカウントが切り替わっていたら捨てる。`_disposed` は build() の
      // 先頭で false へ戻るので、「破棄 → 再 build → 旧 refresh が完了」の順に
      // なるとガードを素通りし、**切替後のアカウントの一覧が切替前の内容で
      // 上書きされる**（遅いサーバーで実際に起きる）。
      if (!identical(ref.read(currentAdapterProvider), adapter)) return;
      state = AsyncData(AnnouncementState(announcements: announcements));
    } catch (_) {
      // 取得失敗。次の機会に取り直す。
    }
  }

  /// Mark an announcement as read.
  Future<void> dismiss(String id) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! AnnouncementSupport) return;

    await (adapter as AnnouncementSupport).dismissAnnouncement(id);

    final current = state.valueOrNull;
    if (current == null) return;

    final updated = current.announcements
        .map((a) => a.id == id ? a.copyWith(read: true) : a)
        .toList();
    state = AsyncData(current.copyWith(announcements: updated));
  }

  /// お知らせのリアクションを付け外しする (#819)。[name] は Unicode 絵文字または
  /// カスタム絵文字の shortcode（コロン無し）。
  ///
  /// まず楽観的にローカル反映してチップを即応答させ、成功後にサーバーの権威値で
  /// 該当お知らせの reactions を reconcile する（新規カスタム絵文字の url や正確な
  /// 件数を取り込む）。失敗時は元の状態へロールバックする。
  Future<void> toggleReaction(
    String id,
    String name, {
    required bool add,
  }) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! AnnouncementReactionSupport) return;

    final current = state.valueOrNull;
    if (current == null) return;
    final original = current.announcements;

    // ロールバック用に対象お知らせの付け外し前スナップショットだけを控える
    // （リスト全体でなく該当 1 件のみ戻すことで、in-flight 中に別お知らせへ
    // 加わった変更を巻き込んで取り消さないようにする）。
    Announcement? originalTarget;
    for (final a in original) {
      if (a.id == id) {
        originalTarget = a;
        break;
      }
    }

    // 楽観更新: 対象お知らせのリアクションを付け外しする。
    final optimistic = original
        .map((a) => a.id == id ? _applyToggle(a, name, add: add) : a)
        .toList();
    state = AsyncData(current.copyWith(announcements: optimistic));

    try {
      if (add) {
        await (adapter as AnnouncementReactionSupport).addAnnouncementReaction(
          id,
          name,
        );
      } else {
        await (adapter as AnnouncementReactionSupport)
            .removeAnnouncementReaction(id, name);
      }

      // サーバーの権威値で該当お知らせの reactions のみ差し替える（read 状態や
      // 並び順などローカルの他状態は保つ）。取得失敗は楽観値のまま握りつぶす。
      try {
        final refreshed = await (adapter as AnnouncementSupport)
            .getAnnouncements();
        Announcement? target;
        for (final a in refreshed) {
          if (a.id == id) {
            target = a;
            break;
          }
        }
        final latest = state.valueOrNull;
        if (target != null && latest != null) {
          final reconciled = latest.announcements
              .map(
                (a) =>
                    a.id == id ? a.copyWith(reactions: target!.reactions) : a,
              )
              .toList();
          state = AsyncData(latest.copyWith(announcements: reconciled));
        }
      } catch (_) {
        // reconcile 失敗は致命的でない（楽観値を維持）。
      }
    } catch (e, st) {
      // API 失敗: 該当お知らせのみ付け外し前の値へ戻す。リスト全体を original で
      // 上書きすると、in-flight 中に別お知らせへ加わった変更まで巻き戻すため
      // （既読化・他お知らせへのリアクション等）、対象 1 件だけ差し替える。
      final latest = state.valueOrNull;
      if (latest != null && originalTarget != null) {
        final reverted = latest.announcements
            .map((a) => a.id == id ? originalTarget! : a)
            .toList();
        state = AsyncData(latest.copyWith(announcements: reverted));
      }
      // 失敗率を host/backend で相関できるよう低頻度計装（#837）。ユーザーには
      // 呼び出し側で SnackBar 通知済みなので赤ではない。
      reportOpFailure(
        tagKey: 'announcement.op',
        operation: add ? 'add_reaction' : 'remove_reaction',
        error: e,
        stackTrace: st,
        account: ref.read(currentAccountProvider),
      );
      rethrow;
    }
  }

  /// 単一お知らせに [name] のリアクションを楽観的に付け外しする。既存チップは
  /// 件数と `me` を増減し、新規は末尾に追加、0 件になったら除去する。新規カスタム
  /// 絵文字の url は reconcile まで不明なため null（その間は shortcode をテキスト
  /// 表示）。
  Announcement _applyToggle(Announcement a, String name, {required bool add}) {
    final reactions = [...a.reactions];
    final idx = reactions.indexWhere((r) => r.name == name);
    if (add) {
      if (idx >= 0) {
        final r = reactions[idx];
        if (r.me) return a; // 既に付けている（多重付与しない）。
        reactions[idx] = r.copyWith(count: r.count + 1, me: true);
      } else {
        reactions.add(AnnouncementReaction(name: name, count: 1, me: true));
      }
    } else {
      if (idx < 0) return a;
      final r = reactions[idx];
      if (!r.me) return a; // 付けていないものは外せない。
      if (r.count <= 1) {
        reactions.removeAt(idx);
      } else {
        reactions[idx] = r.copyWith(count: r.count - 1, me: false);
      }
    }
    return a.copyWith(reactions: reactions);
  }
}

final announcementProvider =
    AsyncNotifierProvider.autoDispose<AnnouncementNotifier, AnnouncementState>(
      AnnouncementNotifier.new,
    );

/// Number of unread announcements (0 while loading or on error).
final unreadAnnouncementCountProvider = Provider.autoDispose<int>((ref) {
  final state = ref.watch(announcementProvider);
  return state.valueOrNull?.announcements.where((a) => !a.read).length ?? 0;
});
