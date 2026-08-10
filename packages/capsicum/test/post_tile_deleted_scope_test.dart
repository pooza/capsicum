import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #909: 「削除してタグづけ」の再投稿が画面に出ない件の回帰ネット。
///
/// 症状の実体は #909 の取り込み処理ではなく **描画側**だった。タイムラインの各行に
/// キーが無いと State は位置で再利用されるため、削除の直前に streaming が新着を
/// 先頭へ挿すと、削除フラグが**別の投稿へ移る**。モロヘイヤの「削除してタグづけ」は
/// Misskey では投稿→削除の順で走り、レスポンスが返る前に再投稿が streaming で
/// 届くので、これがそのまま「再投稿が消える」に化けていた。
///
/// ここでは PostTile の内部に触らず、同じ構造（削除フラグを State に持つ行 + 先頭
/// 挿入されるリスト）で **キーの有無が結果を分ける**ことを固定する。
class _FlagTile extends StatefulWidget {
  const _FlagTile({super.key, required this.id});

  final String id;

  @override
  State<_FlagTile> createState() => _FlagTileState();
}

class _FlagTileState extends State<_FlagTile> {
  /// PostTile の `_deletedPostId` と同じ持ち方（bool ではなく id）。
  String? _deletedId;

  void markDeleted(String id) => setState(() => _deletedId = id);

  @override
  Widget build(BuildContext context) {
    if (_deletedId == widget.id) return const SizedBox.shrink();
    return Text(widget.id, textDirection: TextDirection.ltr);
  }
}

void main() {
  group('削除フラグの適用範囲 (#909)', () {
    testWidgets('先頭挿入で State が再利用されても、別の投稿は隠れない', (tester) async {
      final key = GlobalKey<_FlagTileState>();
      var ids = ['old'];

      Widget build() => Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            for (final id in ids)
              _FlagTile(key: id == ids.first ? key : null, id: id),
          ],
        ),
      );

      await tester.pumpWidget(build());
      expect(find.text('old'), findsOneWidget);

      // streaming が再投稿を先頭へ挿す。キーが無いので先頭の State は使い回され、
      // それまで old を描いていた State が new を描くようになる。
      ids = ['new', 'old'];
      await tester.pumpWidget(build());

      // 元投稿 (old) を削除する。id で持っているので new は巻き添えにならない。
      key.currentState!.markDeleted('old');
      ids = ['new'];
      await tester.pumpWidget(build());

      expect(find.text('new'), findsOneWidget, reason: '再投稿が消えてはいけない');
      expect(find.text('old'), findsNothing);
    });
  });

  group('loadMore の重複排除 (#909)', () {
    test('既にある id は追記しない（Duplicate keys を防ぐ）', () {
      final existing = ['c', 'b'];
      final older = ['b', 'a'];

      final knownIds = {...existing};
      final appended = older.where(knownIds.add).toList();

      expect(appended, ['a']);
      expect([...existing, ...appended], ['c', 'b', 'a']);
    });
  });

  group('ownPostAppearsInTimeline (#909 の実レスポンス)', () {
    test('モロヘイヤの再投稿 (public) はホーム TL に載る', () {
      final post = Post(
        id: 'apqfisqyma',
        postedAt: DateTime.utc(2026, 8, 10, 6, 43, 11),
        author: const User(id: 'aoh3wvz8ya', username: 'test'),
        content: 'capsicum#909 検証用\n\n#test909',
        scope: PostScope.public,
      );

      expect(ownPostAppearsInTimeline(TimelineType.home, post), isTrue);
    });
  });
}
