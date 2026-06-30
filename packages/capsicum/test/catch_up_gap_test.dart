import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #784 / Misskey ASC 対策: live 復帰時のギャップ補完 [collectCatchUpGap] が、
/// 1 ページを超えるギャップでも **新しい側を取りこぼさず** 全件回収することを
/// 検証する。サーバーには maxId のみ（DESC）を渡す前提で、その振る舞いを模した
/// fetch を注入する。Misskey の sinceId 単独 ASC バグ（最古ページしか拾えず
/// 新しい側が永久欠落する）が再発したらここで落ちる。
User _user() => const User(id: 'u1', username: 'alice');

Post _post(String id) =>
    Post(id: id, postedAt: DateTime(2026, 6, 30), author: _user(), content: id);

/// id 降順（新しい順）の世界 [universe] を持つ仮想サーバー。maxId のみで
/// DESC ページングする本番の untilId / max_id 経路を模す。
({Future<CatchUpPage> Function(String?) fetch, List<String> Function() calls})
_server(List<String> universe, {required int pageSize}) {
  final calls = <String>[];
  Future<CatchUpPage> fetch(String? maxId) async {
    calls.add(maxId ?? 'null');
    Iterable<String> avail = universe;
    if (maxId != null) {
      // maxId より古い（降順で後ろ）ものだけ返す。
      avail = universe.where((id) => comparePostIdDesc(id, maxId) > 0);
    }
    final page = avail.take(pageSize).toList();
    return (
      posts: page.map(_post).toList(),
      rawCount: page.length,
      rawLastId: page.isEmpty ? null : page.last,
    );
  }

  return (fetch: fetch, calls: () => calls);
}

void main() {
  group('collectCatchUpGap (#784 / Misskey ASC 対策)', () {
    test('1 ページを超えるギャップでも新しい側を含め全件回収する', () async {
      // since='100' より新しい 5 件（105..101）＋ since 以下（100, 99...）。
      final universe = ['105', '104', '103', '102', '101', '100', '99', '98'];
      final srv = _server(universe, pageSize: 2);

      final gap = await collectCatchUpGap(
        since: '100',
        pageSize: 2,
        maxFetches: 10,
        fetch: srv.fetch,
      );

      // 最古ページ（101 付近）だけでなく、最新側 105/104 も回収されること。
      expect(gap.map((p) => p.id), ['105', '104', '103', '102', '101']);
      // since 自身と古い側は含めない。
      expect(gap.map((p) => p.id), isNot(contains('100')));
      expect(gap.map((p) => p.id), isNot(contains('99')));
    });

    test('ギャップが 1 ページに収まるなら 1 回の取得で打ち切る', () async {
      final universe = ['12', '11', '10', '9'];
      final srv = _server(universe, pageSize: 5);

      final gap = await collectCatchUpGap(
        since: '10',
        pageSize: 5,
        maxFetches: 10,
        fetch: srv.fetch,
      );

      expect(gap.map((p) => p.id), ['12', '11']);
      expect(srv.calls().length, 1, reason: 'アンカーに同ページで到達するため');
    });

    test('since が null のときは最新ページ 1 枚だけシードする', () async {
      final universe = ['30', '29', '28', '27', '26'];
      final srv = _server(universe, pageSize: 2);

      final gap = await collectCatchUpGap(
        since: null,
        pageSize: 2,
        maxFetches: 10,
        fetch: srv.fetch,
      );

      expect(gap.map((p) => p.id), ['30', '29']);
      expect(srv.calls().length, 1, reason: 'シードは 1 ページのみ');
    });

    test('maxFetches の上限でページング暴走を止める', () async {
      // since より新しい投稿が大量にあり、cap までしか辿らない。
      final universe = List.generate(100, (i) => '${200 - i}'); // 200..101
      final srv = _server([...universe, '50'], pageSize: 2);

      final gap = await collectCatchUpGap(
        since: '50',
        pageSize: 2,
        maxFetches: 3,
        fetch: srv.fetch,
      );

      // 3 ページ × 2 = 6 件（最新側から）。cap で打ち切られる。
      expect(gap.length, 6);
      expect(gap.first.id, '200');
      expect(srv.calls().length, 3);
    });

    test('ページ跨ぎの重複 id は除去される', () async {
      final calls = <String?>[];
      Future<CatchUpPage> fetch(String? maxId) async {
        calls.add(maxId);
        if (calls.length == 1) {
          return (posts: [_post('9'), _post('8')], rawCount: 2, rawLastId: '8');
        }
        // 2 ページ目で 8 を重複させる（境界の取りこぼし防止オーバーラップ）。
        return (posts: [_post('8'), _post('7')], rawCount: 2, rawLastId: '7');
      }

      final gap = await collectCatchUpGap(
        since: '5',
        pageSize: 2,
        maxFetches: 2,
        fetch: fetch,
      );

      expect(gap.map((p) => p.id), ['9', '8', '7']);
    });
  });
}
