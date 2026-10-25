import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/git_show.dart';

/// #1329: 外した添付が「同じジャケットを 2 枚添付しない」の判定に残らない。
///
/// ## 何が起きていたか
///
/// 投稿フォームは、ナウプレで足したジャケットの URI を**フォーム側の集合**に
/// 控えていた。添付を外す経路（`_removeAttachment`）はその集合に触れないので、
/// **外してから同じ曲で ♪ を押し直すと `already_attached` で何も付かなかった**
/// （Windows の撮影で見つかった・OS を問わない）。
///
/// 直し方は、集合を持たず、**添付そのもの（`_MediaEntry.nowPlayingArtwork`）に
/// 出どころを持たせて、いま並んでいる添付だけで見る**こと。外せば印ごと消える。
///
/// ⚠ 投稿フォームにはウィジェットテストの足場が無いので、ソースで見る
/// （`docs/CLAUDE.md`「ソース検査ガードの書き方」の 3 点セット）。
void main() {
  const path = 'lib/src/ui/screen/compose_screen.dart';

  group('判定ロジック', () {
    test('フォームに URI の集合で控える形を拾う', () {
      expect(
        heldOutsideAttachments('''
  final Set<Uri> _attachedNowPlayingArtwork = {};
'''),
        isTrue,
      );
      expect(
        heldOutsideAttachments('''
  final _nowPlayingArtworks = <Uri>{};
'''),
        isTrue,
      );
    });

    test('添付に持たせた形・コメントの中の綴りは拾わない', () {
      expect(
        heldOutsideAttachments('''
  // 以前は final Set<Uri> _attachedNowPlayingArtwork = {}; だった
  Uri? nowPlayingArtwork;
'''),
        isFalse,
      );
    });

    test('いま並んでいる添付で見ているか', () {
      expect(
        checksCurrentAttachments(
          '_attachments.any((entry) => entry.nowPlayingArtwork == uri)',
        ),
        isTrue,
      );
      expect(
        checksCurrentAttachments('_attachedNowPlayingArtwork.contains(uri)'),
        isFalse,
      );
    });
  });

  group('実物', () {
    late String source;
    setUpAll(() => source = maskComments(File(path).readAsStringSync()));

    test('⚠ 走査が空振りしていない（ナウプレの添付の経路を読めている）', () {
      expect(source, contains('_attachNowPlayingArtwork'));
      expect(source, contains("'already_attached'"));
      expect(source, contains('void _removeAttachment('));
    });

    test('フォームに別の控えを持たない', () {
      expect(heldOutsideAttachments(source), isFalse);
    });

    test('重複の判定は、いま並んでいる添付で見る', () {
      expect(checksCurrentAttachments(source), isTrue);
    });

    test('足したときに添付へ印を付けている', () {
      expect(source, contains('..nowPlayingArtwork = uri'));
    });
  });

  test('⚠⚠ 直す前（18d54b52）の compose_screen は当たる', () {
    final before = gitShow('18d54b52:packages/capsicum/$path');
    expect(before.exitCode, 0, reason: '${before.stderr}');
    final code = maskComments(before.stdout as String);
    expect(heldOutsideAttachments(code), isTrue);
    expect(checksCurrentAttachments(code), isFalse);
  });
}

/// ナウプレのジャケットの URI を、フォーム側の集合に控えているか。
bool heldOutsideAttachments(String source) => RegExp(
  r'(Set<Uri>\s+_\w*[Nn]ow[Pp]laying\w*\s*=)|'
  r'(_\w*[Nn]ow[Pp]laying\w*\s*=\s*<Uri>\{)',
).hasMatch(maskComments(source));

/// 重複の判定を、いま並んでいる添付（`_attachments`）の印で見ているか。
bool checksCurrentAttachments(String source) => RegExp(
  r'_attachments\.any\(\s*\((\w+)\)\s*=>\s*\1\.nowPlayingArtwork\s*==',
).hasMatch(maskComments(source));
