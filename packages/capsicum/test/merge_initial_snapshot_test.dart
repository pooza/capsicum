import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #921: 起動キャッシュ先出し〜初回 REST 完了の窓（実測 p50 475ms）に行った操作が、
/// 単純な差し替えで黙って捨てられていた。[mergeInitialSnapshot] が
///
/// - 自分の投稿の楽観挿入 (#717) / 窓の間の streaming 新着 → 先頭に残す
/// - `loadMore()` で足した 2 ページ目以降 → 末尾に残す
/// - お気に入り等の差し替え → REST の版でなくこちらを採る
/// - 削除 / ブロック → REST に残っていても戻さない (#887)
///
/// を満たすことを検証する。REST リクエストは操作より前に発行済みで結果を
/// 含まないため、**窓の操作の方が新しい**というのが判定の根拠。
User _user({String id = 'u1'}) => User(id: id, username: 'alice');

Post _post(String id, {String? authorId, String content = 'x'}) => Post(
  id: id,
  postedAt: DateTime(2026, 8, 3),
  author: _user(id: authorId ?? 'u1'),
  content: content,
);

List<String> _ids(List<Post> posts) => posts.map((p) => p.id).toList();

void main() {
  group('mergeInitialSnapshot (#921)', () {
    test('窓で足された新しい投稿を先頭に残す（自分の投稿の楽観挿入）', () {
      // キャッシュ 3 件の先頭に、自分の投稿 '106' が挿さった状態。
      final current = [_post('106'), _post('105'), _post('104'), _post('103')];
      // REST は 1 ページ目（'106' はまだサーバーに index されていない）。
      final fresh = [_post('105'), _post('104'), _post('103')];

      final merged = mergeInitialSnapshot(current: current, fresh: fresh);

      expect(_ids(merged.posts), ['106', '105', '104', '103']);
      expect(merged.hasDeeperPages, isFalse);
    });

    test('loadMore で足した古いページを末尾に残す', () {
      final current = [
        _post('105'),
        _post('104'),
        _post('103'),
        // ここから 2 ページ目
        _post('102'),
        _post('101'),
      ];
      final fresh = [_post('105'), _post('104'), _post('103')];

      final merged = mergeInitialSnapshot(current: current, fresh: fresh);

      expect(_ids(merged.posts), ['105', '104', '103', '102', '101']);
      // 続きがあるかは最深ページが知っている、と呼び出し側に伝える。
      expect(merged.hasDeeperPages, isTrue);
    });

    test('窓で差し替えた投稿は REST の版でなくこちらを採る（お気に入りが戻らない）', () {
      final current = [_post('105'), _post('104')];
      // REST は操作前に発行済みなので、お気に入り前の版が返る。
      final fresh = [_post('105', content: 'stale'), _post('104')];
      final favorited = _post('105', content: 'favorited');

      final merged = mergeInitialSnapshot(
        current: current,
        fresh: fresh,
        updated: {'105': favorited},
      );

      expect(_ids(merged.posts), ['105', '104']);
      expect(merged.posts.first.content, 'favorited');
    });

    test('窓で削除した投稿は REST に残っていても戻さない', () {
      final current = [_post('105'), _post('103')];
      final fresh = [_post('105'), _post('104'), _post('103')];

      final merged = mergeInitialSnapshot(
        current: current,
        fresh: fresh,
        removedIds: {'104'},
      );

      expect(_ids(merged.posts), ['105', '103']);
    });

    test('窓でブロックした相手の投稿は REST に残っていても戻さない (#887)', () {
      final current = [_post('105'), _post('103')];
      final fresh = [
        _post('105'),
        _post('104', authorId: 'blocked'),
        _post('103'),
      ];

      final merged = mergeInitialSnapshot(
        current: current,
        fresh: fresh,
        blockedUserIds: {'blocked'},
      );

      expect(_ids(merged.posts), ['105', '103']);
    });

    test('REST の id 範囲内でサーバーが返さなくなった投稿は落とす', () {
      // キャッシュにあった '104' はサーバー側で削除済み。範囲内は REST が権威。
      final current = [_post('105'), _post('104'), _post('103')];
      final fresh = [_post('105'), _post('103')];

      final merged = mergeInitialSnapshot(current: current, fresh: fresh);

      expect(_ids(merged.posts), ['105', '103']);
    });

    test('キャッシュと 1 件も重ならないときは REST をそのまま採る', () {
      // 24h 近く経って完全に入れ替わった場合。繋げると断絶したリストになる。
      final current = [_post('55'), _post('54')];
      final fresh = [_post('105'), _post('104')];

      final merged = mergeInitialSnapshot(current: current, fresh: fresh);

      expect(_ids(merged.posts), ['105', '104']);
      expect(merged.hasDeeperPages, isFalse);
    });

    test('REST が空なら何もしない（キャッシュを消さない判断は呼び出し側）', () {
      final current = [_post('105')];

      final merged = mergeInitialSnapshot(current: current, fresh: const []);

      expect(merged.posts, isEmpty);
      expect(merged.hasDeeperPages, isFalse);
    });

    test('先頭・末尾・差し替え・削除が同時に起きても取りこぼさない', () {
      final current = [
        _post('106'), // 窓で投稿した自分の投稿
        _post('105'), // 窓でお気に入り
        _post('103'), // '104' は窓で削除
        _post('102'), // loadMore の 2 ページ目
      ];
      final fresh = [
        _post('105', content: 'stale'),
        _post('104'),
        _post('103'),
      ];

      final merged = mergeInitialSnapshot(
        current: current,
        fresh: fresh,
        updated: {'105': _post('105', content: 'favorited')},
        removedIds: {'104'},
      );

      expect(_ids(merged.posts), ['106', '105', '103', '102']);
      expect(merged.posts[1].content, 'favorited');
      expect(merged.hasDeeperPages, isTrue);
    });
  });
}
