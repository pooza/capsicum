import 'dart:io';

import 'package:capsicum/src/ui/util/compose_reset.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1368: 投稿フォームの「入力を空にする…」は、開いたときの状態に戻す。
///
/// | 対象 | 扱い |
/// | --- | --- |
/// | 本文・CW・閲覧注意・添付・アンケート・予約日時 | 消す |
/// | 公開範囲・言語・ローカルのみ・引用の許可・宛先 | 開いたときの値へ戻す |
/// | 返信先・引用先・チャンネル・開いたときのハッシュタグ | 残す |
const _composePath = 'lib/src/ui/screen/compose_screen.dart';

/// [source] の中のメソッド [name] の本体（`{` から対応する `}` まで）。
/// 無ければ null。⚠ コメントと文字列を潰したソースに使う。
String? methodBody(String source, String name) {
  final m = RegExp('void $name\\(\\)\\s*\\{').firstMatch(source);
  if (m == null) return null;
  var depth = 0;
  for (var i = m.end - 1; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return source.substring(m.end - 1, i + 1);
    }
  }
  return null;
}

/// 戻し方の規約を外れているものの説明。
List<String> resetOffenders(String body) => [
  for (final (pattern, what) in _mustReset)
    if (!RegExp(pattern).hasMatch(body)) '戻していない: $what',
  for (final (pattern, what) in _mustKeep)
    if (RegExp(pattern).hasMatch(body)) '触っている: $what',
];

const _mustReset = [
  (r'_controller\.value\s*=\s*composeResetBody\(', '本文'),
  (r'_cwController\.clear\(\)', 'CW の文'),
  (r'_cwEnabled\s*=\s*opening\.defaultSpoilerField', 'CW 欄（既定へ）'),
  (r'_sensitiveEnabled\s*=\s*opening\.defaultSensitive', '閲覧注意（既定へ）'),
  (r'_attachments\.clear\(\)', '添付'),
  (r'_pollEnabled\s*=\s*false', 'アンケート'),
  (r'_scheduledAt\s*=\s*null', '予約日時'),
  (r'_scope\s*=\s*opening\.scope', '公開範囲'),
  (r'_language\s*=\s*opening\.language', '言語'),
  (r'_localOnly\s*=\s*opening\.localOnly', 'ローカルのみ'),
  (r'_quoteApprovalPolicy\s*=\s*opening\.quoteApprovalPolicy', '引用の許可'),
  (r'_clearDraft\(', '自動保存の下書き'),
];

const _mustKeep = [
  (r'_redraftReplyDropped\s*=', '返信をやめたかどうか'),
  (r'_redraftReplyTo\s*=', '返信先'),
  (r'_restoredDraftId\s*=', 'サーバーの下書き'),
];

void main() {
  group('本文', () {
    test('返信なら、返信先へのメンションを入れ直して末尾から書く', () {
      final body = composeResetBody(
        replyMentions: ['alice', 'bob@example.com'],
      );

      expect(body.text, '@alice @bob@example.com ');
      expect(body.selection.baseOffset, body.text.length);
    });

    test('開いたときのハッシュタグを入れ直し、先頭から書く', () {
      final body = composeResetBody(hashtags: ['precure_fun']);

      expect(body.text, '\n\n#precure_fun');
      expect(body.selection.baseOffset, 0);
    });

    test('どちらも無ければ空', () {
      final body = composeResetBody();

      expect(body.text, isEmpty);
      expect(body.selection.baseOffset, 0);
    });

    test('返信が先（返信ではタグを入れない開き方）', () {
      final body = composeResetBody(replyMentions: ['alice'], hashtags: ['x']);

      expect(body.text, '@alice ');
    });
  });

  test('言語だけ控え直しても、ほかの値は変わらない', () {
    const opening = ComposeOpening(
      scope: PostScope.followersOnly,
      language: null,
      localOnly: true,
      quoteApprovalPolicy: 'followers',
      chosen: {'scope'},
      recipientIds: ['u1'],
      defaultSensitive: true,
      defaultSpoilerField: true,
    );
    final next = opening.withLanguage('ja');

    expect(next.language, 'ja');
    expect(next.scope, PostScope.followersOnly);
    expect(next.localOnly, isTrue);
    expect(next.quoteApprovalPolicy, 'followers');
    expect(next.chosen, {'scope'});
    expect(next.recipientIds, ['u1']);
    expect(next.defaultSensitive, isTrue);
    expect(next.defaultSpoilerField, isTrue);
  });

  group('画面の戻し方（_resetCompose）', () {
    final source = maskStrings(
      maskComments(File(_composePath).readAsStringSync()),
    );

    test('走査が空振りしていない: 本体が見つかり、メニューから呼ばれている', () {
      final body = methodBody(source, '_resetCompose');
      expect(body, isNotNull);
      expect(body!.length, greaterThan(500));
      expect(
        source,
        contains('onSelected: busy ? null : _confirmAndResetCompose'),
      );
      expect(source, contains('case _ComposeMenuAction.reset:'));
    });

    test('表のとおりに戻し、残すものに触らない', () {
      expect(resetOffenders(methodBody(source, '_resetCompose')!), isEmpty);
    });

    group('判定（合成ソース）', () {
      final good = methodBody(source, '_resetCompose')!;

      test('戻し忘れを拾う', () {
        final src = good.replaceFirst('_attachments.clear()', '');
        expect(resetOffenders(src), ['戻していない: 添付']);
      });

      test('残すものに触ったら拾う', () {
        final src = good.replaceFirst('{', '{ _redraftReplyDropped = false;');
        expect(resetOffenders(src), ['触っている: 返信をやめたかどうか']);
      });
    });
  });
}
