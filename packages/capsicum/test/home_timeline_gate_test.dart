import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/ui/screen/home_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// HomeScreen が「表示中の TL をスピナーへ潰すか」を決める判定 (#758 / #764 / #890)。
///
/// この判定はホーム画面の見え方そのものなのに、widget テストを組むには
/// アカウント・アダプタ一式が要る。判定だけを純関数に切り出して、条件の
/// 取りこぼし（過去 3 回とも「片方の経路にだけ入っていない」形で出た）を
/// ここで押さえる。
void main() {
  const key = 'misskey://me@example.com|tl:home';
  final data = TimelineState(contextKey: key);

  AsyncValue<TimelineState> settledError() =>
      AsyncValue<TimelineState>.error(Exception('offline'), StackTrace.empty);

  test('期待 contextKey と一致する値はそのまま出す', () {
    expect(
      shouldCollapseToLoading(
        timeline: AsyncData(data),
        expectedContextKey: key,
        pullRefreshing: false,
      ),
      isFalse,
    );
  });

  test('前の文脈の値（contextKey 不一致）はスピナーへ潰す', () {
    expect(
      shouldCollapseToLoading(
        timeline: AsyncData(
          TimelineState(contextKey: 'misskey://other|tl:home'),
        ),
        expectedContextKey: key,
        pullRefreshing: false,
      ),
      isTrue,
      reason: 'アカウント切替直後に前アカウントの投稿を出さない (#758)',
    );
  });

  test('ローディング中はスピナーへ潰す', () {
    expect(
      shouldCollapseToLoading(
        timeline: const AsyncValue<TimelineState>.loading(),
        expectedContextKey: key,
        pullRefreshing: false,
      ),
      isTrue,
    );
  });

  /// v1.53 リリース前レビューの指摘。
  ///
  /// 初回取得が失敗した AsyncError は前値を持たないので `valueOrNull` が null に
  /// なり、contextKey 不一致＝stale として潰されていた。結果、**エラー文も再試行
  /// ボタンも出ないままスピナーが回り続ける**。
  ///
  /// 踏むのは「アカウントの復元は通ったが、タイムライン取得だけ失敗した」とき
  /// （サーバーの部分障害・5xx / 429・復元後に回線が切れた場合）。完全なオフライン
  /// 起動では router が `/server` へ飛ばすためこの画面に到達しない。
  test('決着済みのエラーは潰さない（スピナーが回り続けない）', () {
    expect(
      shouldCollapseToLoading(
        timeline: settledError(),
        expectedContextKey: key,
        pullRefreshing: false,
      ),
      isFalse,
      reason: 'エラー文と再試行導線を出すため、error ブランチまで通す',
    );
  });

  test('エラーを引き継いだリフレッシュ中はスピナーへ潰す', () {
    final refreshing = const AsyncValue<TimelineState>.loading()
        .copyWithPrevious(settledError());

    expect(
      shouldCollapseToLoading(
        timeline: refreshing,
        expectedContextKey: key,
        pullRefreshing: false,
      ),
      isTrue,
      reason: '取り直している最中は前回のエラー文を出したままにしない',
    );
  });

  test('pull-to-refresh 中は現データを残す（リスト消失を防ぐ）', () {
    expect(
      shouldCollapseToLoading(
        timeline: const AsyncValue<TimelineState>.loading(),
        expectedContextKey: key,
        pullRefreshing: true,
      ),
      isFalse,
    );
  });

  test('アカウント未確定（期待キー null）なら潰さない', () {
    expect(
      shouldCollapseToLoading(
        timeline: AsyncData(data),
        expectedContextKey: null,
        pullRefreshing: false,
      ),
      isFalse,
    );
  });
}
