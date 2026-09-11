import 'dart:io';

import 'package:capsicum/src/ui/util/redraft_carry_over.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1113: 「削除して再編集」の引き継ぎ漏れを、**項目が増えたときに落とす**。
///
/// ## ⚠⚠ 同じ形が 4 回続いた
///
/// #703（CW / 添付 / 閲覧注意）→ #756（引用）→ #384（チャンネル）→ #1113
/// （返信先 / ローカルのみ / 言語 / 投票）。**そのたびに 1 項目ずつ足してきた**
/// ので、`PostDraft` に項目が増えるたびに同じ漏れが起きる。
///
/// ⚠ **1 項目ずつ吟味する運用に戻さない。**外部の参照点（両 WebUI の挙動）を
/// 置き、外れる項目は理由を書く。判断そのものは
/// `lib/src/ui/util/redraft_carry_over.dart` の doc が正本。
void main() {
  /// `PostDraft` の項目名を**宣言から読む**。
  ///
  /// ⚠ **テスト側に列挙を書かない。**項目が増えたときに書き足すのを忘れると、
  /// この検査自体が古い母数のまま緑になる（それがこの Issue の形そのもの）。
  Set<String> postDraftFields() {
    final source = maskComments(
      File('../capsicum_core/lib/src/model/post_draft.dart').readAsStringSync(),
    );
    final body = source.substring(source.indexOf('class PostDraft'));
    return RegExp(
      r'final\s+[\w<>,?\s]+?\s+(\w+);',
    ).allMatches(body).map((m) => m.group(1)!).toSet();
  }

  test('探索が空振りしていない', () {
    final fields = postDraftFields();
    expect(
      fields.length,
      greaterThan(10),
      reason: 'PostDraft の項目を読めていない。モデルの書き方が変わったらこの検査も直す',
    );
    // 既知の項目が拾えていること（正規表現が壊れたら空集合でも「漏れ無し」に
    // なってしまう）。
    expect(fields, containsAll(['content', 'inReplyToId', 'localOnly']));
  });

  test('⚠⚠ PostDraft の全項目に態度が宣言されている', () {
    final undeclared =
        postDraftFields()
            .where((f) => !redraftCarryOverPolicy.containsKey(f))
            .toList()
          ..sort();

    expect(
      undeclared,
      isEmpty,
      reason:
          'PostDraft に増えた項目が redraftCarryOverPolicy に無い (#1113)。'
          '⚠ 「引き継ぐ / 意図的に落とす / Post に無い」のどれかを必ず宣言すること。'
          '宣言を忘れると、また 1 項目ずつ漏れる'
          '\n${undeclared.join(', ')}',
    );
  });

  test('⚠ 宣言が古びていない（PostDraft に無い項目が残っていない）', () {
    final fields = postDraftFields();
    final stale =
        redraftCarryOverPolicy.keys.where((k) => !fields.contains(k)).toList()
          ..sort();
    expect(
      stale,
      isEmpty,
      reason:
          'PostDraft から消えた項目の宣言が残っている。'
          '残すと「ここは考慮済み」という嘘の記述になる\n${stale.join(', ')}',
    );
  });

  test('⚠ carry 以外には理由が書いてある', () {
    // ⚠ **理由の無い drop は「まだ実装していない」と区別がつかない。**
    // 投票を落としていた理由（「投票結果がリセットされるため」）は、削除して
    // 再編集では**どのみちリセットされる**ので成立していなかった。
    final missing =
        redraftCarryOverPolicy.entries
            .where((e) => e.value != RedraftCarryOver.carry)
            .map((e) => e.key)
            .where((k) => (redraftCarryOverReasons[k] ?? '').trim().isEmpty)
            .toList()
          ..sort();
    expect(
      missing,
      isEmpty,
      reason: '理由の無い drop / notInPost がある\n${missing.join(', ')}',
    );
  });

  group('返信先の解決', () {
    Post post({String? inReplyToId}) => Post(
      id: 'x',
      author: User(id: 'u', username: 'u'),
      postedAt: DateTime.utc(2026),
      inReplyToId: inReplyToId,
    );

    test('⚠ redraft 元が返信なら、その返信先を引き継ぐ', () {
      expect(
        resolveComposeInReplyToId(null, post(inReplyToId: 'parent')),
        'parent',
      );
    });

    test('返信でなければ null（単独投稿のまま）', () {
      expect(resolveComposeInReplyToId(null, post()), isNull);
    });

    test('replyTo が優先（今回の操作を勝たせる）', () {
      final replyTo = post();
      expect(
        resolveComposeInReplyToId(replyTo, post(inReplyToId: 'parent')),
        replyTo.id,
      );
    });

    test('どちらも無ければ null', () {
      expect(resolveComposeInReplyToId(null, null), isNull);
    });
  });

  group('投票の期限', () {
    const allowed = [300, 1800, 3600, 21600, 43200, 86400, 259200, 604800];
    final now = DateTime.utc(2026, 9, 10, 12);

    test('⚠ 期限切れなら既定へ落とす', () {
      // 2026-09-10 pooza 判断。再投稿は新しい投票なので既定から始める。
      expect(
        redraftPollExpiresIn(
          expiresAt: now.subtract(const Duration(hours: 1)),
          now: now,
          allowed: allowed,
          fallback: 86400,
        ),
        86400,
      );
    });

    test('期限が無ければ既定', () {
      expect(
        redraftPollExpiresIn(
          expiresAt: null,
          now: now,
          allowed: allowed,
          fallback: 86400,
        ),
        86400,
      );
    });

    test('⚠⚠ 残り時間より短い側へ丸めない', () {
      // 残り 40 分。⚠ 30 分へ落とすと、送信までの操作時間で期限切れになりうる。
      expect(
        redraftPollExpiresIn(
          expiresAt: now.add(const Duration(minutes: 40)),
          now: now,
          allowed: allowed,
          fallback: 86400,
        ),
        3600,
      );
    });

    test('選択肢ちょうどならその値', () {
      expect(
        redraftPollExpiresIn(
          expiresAt: now.add(const Duration(hours: 1)),
          now: now,
          allowed: allowed,
          fallback: 86400,
        ),
        3600,
      );
    });

    test('最長より長ければ最長へ寄せる', () {
      expect(
        redraftPollExpiresIn(
          expiresAt: now.add(const Duration(days: 30)),
          now: now,
          allowed: allowed,
          fallback: 86400,
        ),
        604800,
      );
    });
  });

  /// ⚠⚠ **宣言と実装がずれていないこと。**表に `carry` と書いてあるのに
  /// compose が読んでいなければ、表が嘘になる。
  group('ソース検査: carry と宣言した項目を実際に読んでいる', () {
    late String code;

    setUpAll(() {
      code = maskComments(
        File('lib/src/ui/screen/compose_screen.dart').readAsStringSync(),
      );
    });

    test('探索が空振りしていない', () {
      expect(code, contains('redraft.scope'));
    });

    /// `PostDraft` の項目名 → compose 側で redraft から読む形。
    const readSites = <String, String>{
      'localOnly': '_localOnly = redraft.localOnly',
      'language': 'redraft.language',
      'inReplyToId': 'resolveComposeInReplyToId(',
      'pollOptions': 'poll.options.map',
      'pollMultiple': '_pollMultiple = poll.multiple',
      'pollExpiresIn': 'redraftPollExpiresIn(',
      'scope': 'redraft.scope',
      'spoilerText': 'redraft.spoilerText',
      'sensitive': 'redraft.sensitive',
      'mediaIds': 'redraft.attachments',
      'quoteId': 'resolveComposeQuote(',
      'channelId': 'widget.redraft?.channelId',
      'content': 'redraft.content',
      'quoteApprovalPolicy': 'redraft.quoteApprovalPolicy',
    };

    test('readSites が policy の carry を網羅している', () {
      // ⚠ この表自体が古びると、下の検査が「見ていない項目」を通してしまう。
      final carried = redraftCarryOverPolicy.entries
          .where((e) => e.value == RedraftCarryOver.carry)
          .map((e) => e.key)
          .toSet();
      expect(readSites.keys.toSet(), carried);
    });

    /// ⚠⚠ **返信として送るなら、そう見えていること (#1113)。**
    ///
    /// 引き継ぎを足した直後は「返信として投稿されるのに画面のどこにも出ない」
    /// 状態になっていた。**`localOnly` の不具合と同じ「見えないまま効いている」
    /// 型**で、向きが逆なだけ。⚠ **両 WebUI がオブジェクトを持ち回っているのは
    /// 表示できるようにするため**なので、id だけ引き継いで済ませない。
    test('⚠⚠ 表示条件が widget.replyTo の直読みへ戻っていない', () {
      // ⚠ `widget.replyTo != null` で分岐すると、redraft で引き継いだ返信が
      // 表示から漏れる（送信はされるのに画面に出ない）。
      final offenders = <String>[];
      if (code.contains('widget.replyTo != null')) {
        offenders.add('widget.replyTo != null が表示条件に残っている');
      }
      if (!code.contains('bool get _isReply')) {
        offenders.add('_isReply が無い（送信側と同じ判定を使うこと）');
      }
      if (!code.contains('_replyToPost')) {
        offenders.add('_replyToPost が無い（プレビューの元投稿）');
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('⚠ 元投稿を引けなかったときも「返信として投稿します」と出す', () {
      // ⚠ 取得は失敗しうる（消された / 見えない / 通信）。黙ると
      // 「見えないまま効いている」に戻る。
      expect(code, contains('_redraftReplyToUnavailable'));
      expect(
        maskStrings(code).contains('_redraftReplyToUnavailable'),
        isTrue,
        reason: 'コメントや文字列ではなく実際の分岐であること',
      );
    });

    test('⚠ 送信は取得の成否に依存しない', () {
      // ⚠ **プレビューが出なくても返信として送る。**送信は id だけを使う。
      expect(code, contains('resolveComposeInReplyToId('));
      expect(
        code.contains('inReplyToId: _replyToPost'),
        isFalse,
        reason: '送信が取得結果に依存している。引けなかったら返信が外れてしまう',
      );
    });

    test('⚠ carry と宣言した項目を compose が読んでいる', () {
      final missing = <String>[];
      readSites.forEach((field, marker) {
        if (!code.contains(marker)) missing.add('$field ($marker)');
      });
      expect(
        missing,
        isEmpty,
        reason:
            'policy が carry と宣言しているのに、compose が redraft から'
            '読んでいない (#1113)。表が嘘になっている\n${missing.join('\n')}',
      );
    });
  });

  /// ⚠⚠ **引き継ぐ元の値を、アダプターが実際に入れていること (#1113)。**
  ///
  /// 上の検査は「宣言」と「compose が読むこと」しか見ていない。2026-09-12 の
  /// 実機確認で、**Misskey の変換が `replyId` を `inReplyToId` へ入れていなかった**
  /// ことが分かった。compose は正しく読んでいたが、読む値が最初から null だった
  /// ので、Misskey の返信は再編集で単独の投稿になっていた。**検査は全部緑だった。**
  group('ソース検査: carry と宣言した項目をアダプターが Post へ入れている', () {
    /// `PostDraft` の項目名 → 変換（`toCapsicum`）で埋める `Post` の引数名。
    const postArgs = <String, String>{
      'content': 'content',
      'scope': 'scope',
      'inReplyToId': 'inReplyToId',
      'quoteId': 'quote',
      'mediaIds': 'attachments',
      'spoilerText': 'spoilerText',
      'sensitive': 'sensitive',
      'localOnly': 'localOnly',
      'channelId': 'channelId',
      'language': 'language',
      'pollOptions': 'poll',
      'pollExpiresIn': 'poll',
      'pollMultiple': 'poll',
      'quoteApprovalPolicy': 'quoteApprovalPolicy',
    };

    /// 変換元のファイルと、その中の変換を見つける目印。
    const sources = <String, (String, String)>{
      'mastodon': (
        '../capsicum_backends/lib/src/mastodon/extensions.dart',
        'on MastodonStatus',
      ),
      'misskey': (
        '../capsicum_backends/lib/src/misskey/extensions.dart',
        'on MisskeyNote',
      ),
    };

    /// そのサーバーに**概念が無い**ので入れようがない項目。⚠ **理由を書くこと。**
    /// 「まだ入れていない」をここへ書くと、今回の穴がそのまま戻る。
    const notApplicable = <String, Map<String, String>>{
      'mastodon': {
        'localOnly': '本家 Mastodon に「ローカルのみ」が無い',
        'channelId': 'Mastodon にチャンネルが無い',
      },
      'misskey': {
        'language': 'Misskey の投稿に言語の項目が無い',
        'quoteApprovalPolicy': 'Misskey に引用許可の概念が無い',
      },
    };

    Set<String> carried() => redraftCarryOverPolicy.entries
        .where((e) => e.value == RedraftCarryOver.carry)
        .map((e) => e.key)
        .toSet();

    Set<String> argsOf(String backend) {
      final (path, anchor) = sources[backend]!;
      return postConstructorArgs(File(path).readAsStringSync(), anchor);
    }

    test('探索が空振りしていない', () {
      for (final backend in sources.keys) {
        final args = argsOf(backend);
        expect(
          args.length,
          greaterThan(10),
          reason: '$backend の Post(...) の引数を読めていない',
        );
        expect(
          args,
          containsAll(['id', 'content', 'scope', 'poll']),
          reason: '$backend: 既知の引数が拾えていない',
        );
      }
    });

    test('引数の読み取り: コメント・文字列・入れ子の名前付き引数を拾わない', () {
      const source = '''
extension X on MisskeyNote {
  Post toCapsicum() {
    final a = Other(scope: 1);
    return Post(
      id: id,
      // inReplyToId: replyId,
      content: 'label: text',
      poll: parse(expiresAt: e, items: [a, b], map: {'k': v}),
      spoilerText: cw, sensitive: s,
    );
  }
}
''';
      expect(postConstructorArgs(source, 'on MisskeyNote'), {
        'id',
        'content',
        'poll',
        'spoilerText',
        'sensitive',
      });
    });

    test('postArgs が policy の carry を網羅している', () {
      // ⚠ この表が古びると、下の検査が「見ていない項目」を通してしまう。
      expect(postArgs.keys.toSet(), carried());
    });

    test('notApplicable は carry の項目だけで、理由が書いてある', () {
      notApplicable.forEach((backend, fields) {
        expect(
          carried(),
          containsAll(fields.keys),
          reason: '$backend: carry でない項目が notApplicable にある',
        );
        for (final entry in fields.entries) {
          expect(
            entry.value.trim(),
            isNotEmpty,
            reason: '$backend.${entry.key} の理由が空',
          );
        }
      });
    });

    test('⚠⚠ carry の項目を両アダプターが Post へ入れている', () {
      final missing = <String>[];
      for (final backend in sources.keys) {
        final args = argsOf(backend);
        for (final field in carried()) {
          if (notApplicable[backend]!.containsKey(field)) continue;
          if (!args.contains(postArgs[field])) {
            missing.add('$backend: $field（Post.${postArgs[field]}）');
          }
        }
      }
      expect(
        missing,
        isEmpty,
        reason:
            'carry と宣言した項目を、変換が Post へ入れていない (#1113)。'
            '再編集で引き継ぐ元の値が最初から null になる'
            '\n${missing.join('\n')}',
      );
    });

    test('⚠ notApplicable が古びていない（実は入れている項目が残っていない）', () {
      // 概念が無いと書いた項目を変換が入れ始めたら、宣言が嘘になっている。
      final stale = <String>[];
      notApplicable.forEach((backend, fields) {
        final args = argsOf(backend);
        for (final field in fields.keys) {
          if (args.contains(postArgs[field])) stale.add('$backend: $field');
        }
      });
      expect(stale, isEmpty, reason: stale.join('\n'));
    });
  });
}

/// [anchor] より後ろにある最初の `Post(...)` の、**直下の名前付き引数**の名前。
///
/// コメントと文字列を潰してから、括弧の深さ 1 の `,` で区切って `名前:` を拾う。
/// ⚠ 入れ子の呼び出し（`parse(expiresAt: e)`）やコレクションの中は数えない。
Set<String> postConstructorArgs(String source, String anchor) {
  final code = maskStrings(maskComments(source));
  final from = code.indexOf(anchor);
  if (from < 0) return {};
  final start = RegExp(r'\bPost\(').firstMatch(code.substring(from));
  if (start == null) return {};
  final open = from + start.end - 1;

  final segments = <String>[];
  var depth = 0;
  var segmentStart = open + 1;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) {
        segments.add(code.substring(segmentStart, i));
        break;
      }
    } else if (c == ',' && depth == 1) {
      segments.add(code.substring(segmentStart, i));
      segmentStart = i + 1;
    }
  }
  final name = RegExp(r'^\s*(\w+)\s*:');
  return {
    for (final s in segments)
      if (name.firstMatch(s) case final m?) m.group(1)!,
  };
}
