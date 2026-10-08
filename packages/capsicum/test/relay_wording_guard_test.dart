import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1226: 利用者が読む文言に**裸の「リレー」**を出さない。
///
/// ## なぜ要るか
///
/// ⚠⚠ **Fedi では「リレー」は ActivityPub のリレーを指す。**サーバー間で投稿を
/// 中継するあれと、capsicum のプッシュ通知の中継サーバーは別物なので、裸で
/// 「リレー」と書くと混同される（2026-10-04 pooza）。
///
/// ⚠ **改称ではない。**既に露出しているので引っ込められない:
///
/// - capsicum-site の**特商法表記の商品名**が「プッシュ通知リレーの利用権」
/// - 利用規約・プライバシーポリシーも同じ語
/// - **公開済みストアの投げ銭商品の説明文**が「開発と通知リレー運用への応援」
///   （v1.27〜・購入者 46 人）
///
/// ⚠⚠ **既出はすべて複合語**（「プッシュ通知リレー」「通知リレー」）で、裸の
/// 「リレー」はアプリ内にしか無かった。この検査はそこを塞ぐ。
///
/// ## 判定
///
/// **「リレー」の直前 2 文字が「通知」であること。**
///
/// ⚠ **列挙をやめ、構造で見る**（`docs/CLAUDE.md`「ソース検査ガードの書き方」）。
/// 許される複合語の表を持つと、次に増えた綴りが黙って通る。「直前が通知」なら
/// 「プッシュ通知リレー」「通知リレーサーバー」は通り、**新しい裸の用法は必ず
/// 当たる**。
///
/// ⚠⚠ **コメントは潰すが、文字列リテラルは潰さない。**探しているものそのもの
/// だから。⚠ Dart の識別子は ASCII のみなので、**コメントを潰したあとに残る
/// 「リレー」は文字列リテラルの中にしか無い**（だから「リテラルを取り出す」
/// 処理は要らない）。
///
/// ⚠ **文字列連結で「通知」と「リレー」を割らないこと**も、この判定で当たる。
/// 割ると `grep` でも追えなくなるので、当たるのは意図どおり。
void main() {
  final libDir = Directory('lib');
  final sources = sourceFiles(libDir.path);

  /// 裸の「リレー」を書いている行を返す。
  List<String> offendersIn(String source) {
    final masked = maskComments(source);
    final hits = <String>[];
    final lines = masked.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (var at = line.indexOf('リレー'); at != -1;) {
        final prefix = at >= 2 ? line.substring(at - 2, at) : '';
        if (prefix != '通知') hits.add('${i + 1}: ${line.trim()}');
        at = line.indexOf('リレー', at + 1);
      }
    }
    return hits;
  }

  group('⚠ 走査が空振りしていない', () {
    test('lib の走査が実際にファイルを拾っている', () {
      expect(sources.length, greaterThan(100));
    });

    test('⚠⚠ 置き換え後の形が実在する', () {
      // ⚠ 「裸が無い」だけを見ると、**どちらも無い**（文言ごと消えた・走査が
      // 外れた）で緑になる。置き換え後の綴りが実際に在ることを別に固定する。
      final withCompound = sources
          .where((f) => f.readAsStringSync().contains('プッシュ通知リレー'))
          .map((f) => f.path)
          .toList();
      expect(
        withCompound.length,
        greaterThanOrEqualTo(4),
        reason: '「プッシュ通知リレー」を持つファイル: $withCompound',
      );
    });

    test('⚠ 既出の複合語を持つ画面が走査に入っている', () {
      final paths = sources.map((f) => f.path).toList();
      expect(
        paths,
        contains('lib/src/ui/screen/settings/supporter_screen.dart'),
      );
      expect(
        paths,
        contains(
          'lib/src/ui/screen/settings/push_notification_settings_screen.dart',
        ),
      );
      expect(
        paths,
        contains('lib/src/ui/widget/relay_entitlement_purchase_section.dart'),
      );
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('裸の「リレー」は当たる', () {
      const samples = [
        "const Text('リレーの利用権');",
        "errorMessage: 'リレーサーバーに接続できません';",
        "const SectionHeader('リレー');",
        // ⚠ 連結で「通知」と割れた形。grep で追えなくなるので当てる。
        "const Text('プッシュ通知'\n    'リレーの利用権');",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isNotEmpty, reason: sample);
      }
    });

    test('複合語は当たらない', () {
      const samples = [
        "const Text('プッシュ通知リレーの利用権');",
        "const Text('投げ銭で開発と通知リレーを応援');",
        "errorMessage: 'プッシュ通知リレーサーバーの応答が不正です';",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isEmpty, reason: sample);
      }
    });

    test('⚠ コメントの中は当たらない', () {
      // ⚠ 設計の説明で「リレー」と書けないと、検査ごと外されてしまう。
      const samples = [
        '// リレーの利用権を relay へ送る\nconst x = 1;',
        '/// 有償リレーの利用権の購入導線 (#597)。\nconst x = 1;',
        '/* リレー */\nconst x = 1;',
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isEmpty, reason: sample);
      }
    });

    test('⚠ 同一行に URL があってもコメント落としで消えない', () {
      // ⚠ 素朴な indexOf('//') だと `https://` で行末まで消える (#1035-C5)。
      const sample = "const url = 'https://capsicum.shrieker.net'; // リレーの説明";
      expect(offendersIn(sample), isEmpty, reason: sample);
    });
  });

  group('⚠⚠ 歯があることを、実物で穴を開けて確かめる', () {
    test('修正前の push_notification_settings_screen は当たる', () {
      // ⚠⚠ **SHA で固定する。**`HEAD:` だと #1226 の修正がコミットされた瞬間に
      // **修正後**のファイルを取り出して当たらなくなる。`5c915b11` は #1226 の
      // 修正を入れる直前の develop の tip。`analyze.yml` は `fetch-depth: 0`
      // なので CI でも引ける。
      final before = Process.runSync('git', [
        'show',
        '5c915b11:packages/capsicum/lib/src/ui/screen/settings/'
            'push_notification_settings_screen.dart',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      final source = before.stdout as String;
      expect(
        source,
        contains('showRelayPurchaseEntry'),
        reason: '取り出したのが本当に修正前のファイルであること',
      );
      expect(
        offendersIn(source),
        isNotEmpty,
        reason: '修正前は「リレーの利用権」と裸で書いていたので、当たらなければ歯が無い',
      );
    });
  });

  test('lib に裸の「リレー」は無い', () {
    final offenders = <String>[];
    for (final file in sources) {
      for (final hit in offendersIn(file.readAsStringSync())) {
        offenders.add('${file.path} $hit');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '利用者が読む文言の「リレー」は「通知」と続けて書く'
          '（「プッシュ通知リレー」/「通知リレー」）。#1226',
    );
  });
}
