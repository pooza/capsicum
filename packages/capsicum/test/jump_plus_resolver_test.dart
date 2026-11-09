import 'package:capsicum/src/service/jump_plus_resolver.dart';
import 'package:capsicum/src/url_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1352: 少年ジャンプ＋の「勇者アバンと獄炎の魔王」だけ、アプリの作品ページで
/// 開く（2026-11-10 pooza・決め打ち）。
///
/// `<title>` は 2026-11-10 に実物のページから写した。
const _abanFirst =
    '<html><head><title>[第1話]ドラゴンクエスト ダイの大冒険 勇者アバンと獄炎の魔王 - '
    '三条陸/芝田優作 | 少年ジャンプ＋</title></head></html>';
const _aban66 =
    '<title>[第66話 後編]ドラゴンクエスト ダイの大冒険 勇者アバンと獄炎の魔王 - '
    '三条陸/芝田優作 | 少年ジャンプ＋</title>';

/// ほかの作品のページ。おすすめ欄にアバンの名前やサムネイルが並ぶことがある。
const _otherWithAbanRecommended =
    '<title>[1話]忘却バッテリー - みかわ絵子 | 少年ジャンプ＋</title>'
    '<img alt="ドラゴンクエスト ダイの大冒険 勇者アバンと獄炎の魔王" '
    'src="https://x/series-thumbnail/3269754496819320007">';

void main() {
  group('話のページの URL か', () {
    test('当たる', () {
      for (final url in [
        'https://shonenjumpplus.com/episode/3269754496819320015',
        'https://shonenjumpplus.com/episode/9253191257382361145/',
        'https://ShonenJumpPlus.com/episode/1',
      ]) {
        expect(isJumpPlusEpisodeUrl(Uri.parse(url)), isTrue, reason: url);
      }
    });

    test('当たらない', () {
      for (final url in [
        'https://shonenjumpplus.com/',
        'https://shonenjumpplus.com/series',
        'https://shonenjumpplus.com/app/episode/ew109801',
        'https://shonenjumpplus.com/episode/abc',
        'http://shonenjumpplus.com/episode/1',
        'https://example.com/episode/1',
      ]) {
        expect(isJumpPlusEpisodeUrl(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });

  group('アバンのページか', () {
    test('アバンの話のページ（第 1 話・最新話）', () {
      expect(isAbanEpisodePage(_abanFirst), isTrue);
      expect(isAbanEpisodePage(_aban66), isTrue);
    });

    test('⚠⚠ おすすめ欄にアバンが並ぶだけのほかの作品は、アバンとみなさない', () {
      expect(isAbanEpisodePage(_otherWithAbanRecommended), isFalse);
    });
  });

  group('アプリで開く URL', () {
    test('アバンなら作品ページ（ew109801）', () async {
      final url = await jumpPlusAppUrlFor(
        Uri.parse('https://shonenjumpplus.com/episode/1001'),
        fetch: (_) async => _aban66,
      );

      expect(url, Uri.parse('https://shonenjumpplus.com/app/episode/ew109801'));
    });

    test('ほかの作品なら null（ブラウザで開く）', () async {
      final url = await jumpPlusAppUrlFor(
        Uri.parse('https://shonenjumpplus.com/episode/1002'),
        fetch: (_) async => _otherWithAbanRecommended,
      );

      expect(url, isNull);
    });

    test('⚠ 取得に失敗したら null（リンクは開かなくならない）', () async {
      final url = await jumpPlusAppUrlFor(
        Uri.parse('https://shonenjumpplus.com/episode/1003'),
        fetch: (_) async => throw Exception('timeout'),
      );

      expect(url, isNull);
    });

    test('話のページでなければ取りに行かない', () async {
      var fetched = 0;
      final url = await jumpPlusAppUrlFor(
        Uri.parse('https://shonenjumpplus.com/series'),
        fetch: (_) async {
          fetched++;
          return _aban66;
        },
      );

      expect(url, isNull);
      expect(fetched, 0);
    });

    test('同じリンクは 2 回目から取りに行かない', () async {
      var fetched = 0;
      Future<String?> fetch(Uri _) async {
        fetched++;
        return _abanFirst;
      }

      final uri = Uri.parse('https://shonenjumpplus.com/episode/1004');
      await jumpPlusAppUrlFor(uri, fetch: fetch);
      final second = await jumpPlusAppUrlFor(uri, fetch: fetch);

      expect(second, isNotNull);
      expect(fetched, 1);
    });

    test('⚠ 失敗は覚えない（次に押したときは取り直す）', () async {
      var fetched = 0;
      final uri = Uri.parse('https://shonenjumpplus.com/episode/1005');
      await jumpPlusAppUrlFor(
        uri,
        fetch: (_) async {
          fetched++;
          throw Exception('timeout');
        },
      );
      final second = await jumpPlusAppUrlFor(
        uri,
        fetch: (_) async {
          fetched++;
          return _abanFirst;
        },
      );

      expect(second, isNotNull);
      expect(fetched, 2);
    });
  });

  group('サービスの表', () {
    test('ジャンプ＋は表にあり、外せる', () {
      expect(hasPreferredApp('shonenjumpplus.com'), isTrue);
      expect(
        hasPreferredApp('shonenjumpplus.com', disabled: {'jumpplus_aban'}),
        isFalse,
      );
    });

    test('URL を求めないサービスは、押した URL をそのまま渡す', () async {
      final github = preferredAppServiceFor('github.com')!;
      final uri = Uri.parse('https://github.com/pooza/capsicum');

      expect(await preferredAppUriFor(github, uri), uri);
    });

    test('⚠ 求める処理が投げたら null（ブラウザで開く）', () async {
      final service = PreferredAppService('broken', '壊れた', const {
        'example.com',
      }, appUrlFor: (_) async => throw StateError('boom'));

      expect(
        await preferredAppUriFor(service, Uri.parse('https://example.com/')),
        isNull,
      );
    });
  });
}
