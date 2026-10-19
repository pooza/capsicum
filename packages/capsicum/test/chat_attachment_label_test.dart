import 'dart:io';

import 'package:capsicum/src/provider/channel_provider.dart';
import 'package:capsicum/src/util/chat_attachment_label.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1304（v2.4 リリース前レビューの送り分）: 同じ処理が散っていたものを 1 本に
/// 寄せた 2 件。
void main() {
  group('メッセージの添付の表記', () {
    test('MIME 型から種類を出す（GIF は画像）', () {
      expect(chatAttachmentTypeFromMime('image/png'), AttachmentType.image);
      expect(chatAttachmentTypeFromMime('image/gif'), AttachmentType.image);
      expect(chatAttachmentTypeFromMime('video/mp4'), AttachmentType.video);
      expect(chatAttachmentTypeFromMime('audio/ogg'), AttachmentType.audio);
      expect(
        chatAttachmentTypeFromMime('application/pdf'),
        AttachmentType.unknown,
      );
    });

    test('種類ごとの表記', () {
      expect(chatAttachmentLabel(AttachmentType.image), '[画像]');
      expect(chatAttachmentLabel(AttachmentType.unknown), '[ファイル]');
    });

    // ⚠ 集約の再発は「使わなくなること」として現れる。表記の文字列が正本の外に
    // 戻っていないことを見る。
    final literal = RegExp(r"'\[(?:画像|動画|音声|GIF|ファイル)\]'");
    int hitsIn(String source) =>
        literal.allMatches(maskComments(source)).length;

    test('⚠ 判定に合成ソースを食わせる', () {
      expect(hitsIn("Text('[ファイル]')"), 1);
      expect(hitsIn("// '[画像]' と書かない"), 0);
    });

    test('⚠⚠ 修正前の通知の振り分けは当たる', () {
      final before = Process.runSync('git', [
        'show',
        'b5d6147f:packages/capsicum/lib/src/service/push_message_dispatcher.dart',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      expect(hitsIn(before.stdout as String), 4);
    });

    test('表記は chat_attachment_label.dart の 1 本だけ', () {
      final offenders = [
        for (final file in sourceFiles('lib'))
          if (file.path != 'lib/src/util/chat_attachment_label.dart' &&
              hitsIn(file.readAsStringSync()) > 0)
            file.path,
      ];
      expect(offenders, isEmpty);
    });
  });

  group('channelNameFromFollowed', () {
    const followed = [Channel(id: 'c1', name: 'プリキュア')];

    test('保存された名前を先に使う', () {
      expect(channelNameFromFollowed('c1', '保存名', followed), '保存名');
    });

    test('名前が無ければフォロー中の一覧から引く', () {
      expect(channelNameFromFollowed('c1', null, followed), 'プリキュア');
    });

    test('どちらにも無ければ null（扱いは呼ぶ側が決める）', () {
      expect(channelNameFromFollowed('c2', null, followed), isNull);
      expect(channelNameFromFollowed('c1', null, null), isNull);
    });
  });
}
