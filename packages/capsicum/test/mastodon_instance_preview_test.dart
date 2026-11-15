import 'package:capsicum/src/ui/util/mastodon_instance_preview.dart';
import 'package:flutter_test/flutter_test.dart';

/// ログイン画面に出すサーバーの見出し（#658 / #1287）。
void main() {
  group('v2', () {
    test('名前・説明・バナー → アイコンの順の候補', () {
      final p = mastodonInstancePreviewFromV2({
        'title': '美食丼',
        'description': '<p>説明</p>',
        'thumbnail': {'url': 'https://m.example/site_uploads/banner.png'},
        'icon': [
          {'src': 'https://m.example/icon-48.png', 'size': '48x48'},
          {'src': 'https://m.example/icon-192.png', 'size': '192x192'},
        ],
      });
      expect(p.name, '美食丼');
      expect(p.description, '<p>説明</p>');
      expect(p.imageCandidates, [
        ('https://m.example/site_uploads/banner.png', true),
        ('https://m.example/icon-192.png', false),
      ]);
    });

    test('⚠ バンドルのデフォルト preview 画像は候補にしない', () {
      final p = mastodonInstancePreviewFromV2({
        'thumbnail': {'url': 'https://m.example/packs/media/preview-abc.png'},
      });
      expect(p.imageCandidates.first.$1, isNull);
    });
  });

  // #1287: v2 が無いサーバー（Akkoma）。v1 の thumbnail は文字列。
  group('v1', () {
    test('Akkoma の形（thumbnail が文字列）を読む', () {
      final p = mastodonInstancePreviewFromV1({
        'title': 'モロヘイヤ Akkoma 検証環境',
        'description': 'Akkoma: The cooler fediverse server',
        'short_description': 'short',
        'thumbnail': 'https://a.example/instance/thumbnail.jpeg',
      });
      expect(p.name, 'モロヘイヤ Akkoma 検証環境');
      expect(p.description, 'Akkoma: The cooler fediverse server');
      expect(p.imageCandidates, [
        ('https://a.example/instance/thumbnail.jpeg', true),
      ]);
    });

    test('説明が空なら short_description', () {
      final p = mastodonInstancePreviewFromV1({
        'description': '',
        'short_description': '短い説明',
      });
      expect(p.description, '短い説明');
    });

    test('⚠ thumbnail が文字列でなければ候補を空にする（落ちない）', () {
      final p = mastodonInstancePreviewFromV1({
        'thumbnail': {'url': 'x'},
      });
      expect(p.imageCandidates.single.$1, isNull);
      expect(p.name, isNull);
      expect(p.description, '');
    });

    test('⚠ v1 でもデフォルト preview 画像は候補にしない', () {
      final p = mastodonInstancePreviewFromV1({
        'thumbnail': 'https://m.example/packs/media/preview-abc.png',
      });
      expect(p.imageCandidates.single.$1, isNull);
    });
  });
}
