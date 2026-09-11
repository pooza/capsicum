import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1024: `logout` と `removeOfflineAccount` の後始末が食い違わないようにする。
///
/// この 2 つは**ユーザーから見て同じ操作**（アカウントを消す）。片方は接続中の
/// アカウント、もう片方は未接続 (#792 / #967) が相手というだけ。にもかかわらず
/// 掃除は別々に書かれており、**追加のたびに片方だけへ足されてきた**。
///
/// | 追加された掃除 | 経緯 |
/// | --- | --- |
/// | 下書きスロット (#964) | `logout` だけ → #1014 で追随 |
/// | 通知ラベル・push 鍵 (#770) | `logout` だけ → **#1024 で追随** |
///
/// ⚠⚠ **`removeOfflineAccount` の真上には「[logout] と同じ後始末を漏らさない
/// こと」と書いてある。**それでも #1024 は起きた。**doc は守らせる力を持たない**
/// ので、機械で止める。
///
/// この検査は「掃除の一覧が両方に載っていること」を見る。**掃除そのものの
/// 正しさは見ない**（それは各 store のテストが持つ）。新しい掃除を `logout` へ
/// 足すと、[cleanups] を更新するまで落ちる = 未接続側をどうするか必ず考える
/// ことになる、という形。
void main() {
  const source = 'lib/src/provider/account_manager_provider.dart';

  /// 両経路が持つべき掃除。
  ///
  /// `offline` が `logout` と違うのは **push の解除だけ**で、これは意図的。
  /// 未接続アカウントは adapter もアクセストークンも持たないので、SNS 側へ
  /// unsubscribe を投げようがない。端末側の掃除は
  /// `forgetAccountLocally` として共有している。
  const cleanups = <({String what, String logout, String offline})>[
    (
      what: 'push の解除',
      logout: 'PushRegistrationService.unregisterAccount(',
      // ⚠ 上流の unsubscribe は不可能。端末側だけ消す（doc は
      // PushRegistrationService.forgetAccountLocally 側にある）。
      offline: 'PushRegistrationService.forgetAccountLocally(',
    ),
    (
      what: '通知ラベルの表示名キャッシュ',
      logout: 'NotificationLabelCache.remove(',
      offline: 'NotificationLabelCache.remove(',
    ),
    (
      what: 'secret の削除',
      logout: 'storage.removeAccount(',
      offline: 'storage.removeAccount(',
    ),
    (
      what: 'TL キャッシュ',
      logout: 'TimelineCache.clear(',
      offline: 'TimelineCache.clear(',
    ),
    (
      what: '書きかけの自動保存スロット',
      logout: 'ComposeDraftStore.clearForAccount(',
      offline: 'ComposeDraftStore.clearForAccount(',
    ),
    (
      what: 'Windows の push_labels.json',
      logout: '_syncWindowsPushLabels(',
      offline: '_syncWindowsPushLabels(',
    ),
  ];

  /// 掃除ではないので一覧に要らない呼び出し。**増やすときは理由を書くこと。**
  const notCleanup = <String>{
    // 残ったアカウントの再選択。掃除ではなく state の組み替え。
    'state.accounts.where(',
    'state.offlineAccounts.where(',
    'state.copyWith(',
    'remaining.isNotEmpty',
    // key の文字列化。掃除の引数を作っているだけ。
    'account.key.toStorageKey(',
    'key.toStorageKey(',
    '_notificationLabelKey(',
    'ref.read(',
    // 一覧から外す（掃除ではなく表示状態）。
    '_removeOffline(',
  };

  /// [name] のメソッド本体を、`{` と対応する `}` まで切り出す。
  ///
  /// ⚠ 文字列リテラル中の括弧は数えない。ここを雑にすると `'{'` を含む文言で
  /// 抽出が静かに壊れ、**空文字列を検査して緑になる**。
  String bodyOf(String source, String name) {
    final head = RegExp('Future<void> $name\\([^)]*\\) async \\{');
    final m = head.firstMatch(source);
    expect(m, isNotNull, reason: '$name を見つけられない。シグネチャが変わったらこの検査も直す');
    var depth = 0;
    String? quote;
    for (var i = m!.end - 1; i < source.length; i++) {
      final c = source[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(m.end, i);
      }
    }
    fail('$name の終端を見つけられない');
  }

  /// 行コメントを落とす。doc やコメントでの言及を呼び出しと取り違えない。
  ///
  /// ⚠ **文字列リテラルを見る版へ寄せた (#1035-C5)。**素朴な `indexOf('//')` は
  /// 同一行に URL リテラルがあると**そこから行末までを丸ごと消す**。同じ実装が
  /// 3 本のガードへ写されていたので、[maskComments] に統一した。
  String stripLineComments(String s) => maskComments(s);

  late String logoutBody;
  late String offlineBody;

  setUpAll(() {
    final text = File(source).readAsStringSync();
    logoutBody = stripLineComments(bodyOf(text, 'logout'));
    offlineBody = stripLineComments(bodyOf(text, 'removeOfflineAccount'));
  });

  test('抽出そのものが壊れていない', () {
    // 空を検査して緑になる形を先に潰す。
    expect(logoutBody.length, greaterThan(200));
    expect(offlineBody.length, greaterThan(200));
    expect(logoutBody, contains('storage.removeAccount('));
  });

  for (final c in cleanups) {
    test('${c.what}: logout にある', () {
      expect(logoutBody, contains(c.logout));
    });

    test('${c.what}: removeOfflineAccount にもある (#1024)', () {
      expect(
        offlineBody,
        contains(c.offline),
        reason:
            '「${c.what}」が未接続アカウントの削除経路に無い。ユーザーから見れば '
            'logout と同じ操作なので、痕跡を残す理由が無い',
      );
    });
  }

  test('logout に、一覧へ載っていない掃除が増えていない (#1024)', () {
    final known = {
      ...cleanups.map((c) => c.logout),
      ...cleanups.map((c) => c.offline),
      ...notCleanup,
    };
    // `await` している呼び出し = 何かを外部へ書き出している疑いがあるもの。
    final awaited = RegExp(
      r'await\s+([A-Za-z_][\w.]*\()',
    ).allMatches(logoutBody).map((m) => m.group(1)!).toSet();

    final unknown = awaited.where((call) => !known.contains(call)).toList();
    expect(
      unknown,
      isEmpty,
      reason:
          'logout に新しい掃除が入った。cleanups へ足して、'
          'removeOfflineAccount 側をどうするか決めること。'
          '**未接続アカウントにも同じ痕跡が残る**のが既定であって、'
          '「接続中だけの話」と決めつけないこと (#1024)',
    );
  });
}
