import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1136: secure storage を**名前で握って直に叩く**クラスを作らせない。
///
/// ## なぜ要るか
///
/// [#1117](https://github.com/pooza/capsicum/issues/1117)-C は、応答しない
/// キーリングに触って**描くスレッドごと止まる**のを防ぐ関所（疎通確認 + 上限）を
/// 入れた。⚠⚠ **ところが関所を `AccountStorage` の中に置いたので、同じ資源を
/// 触る `PushKeyStore` / `DeviceInstallId` には掛からなかった** —— どちらも
/// `FlutterSecureStorage` を自前で持ち、`SecretServiceProbe` の参照が
/// **ゼロ**だった。実際にアカウント削除の裏で `PushKeyStore.delete` が走り、
/// **画面が固まった**（2026-09-13・Linux 機での実測）。
///
/// ⚠⚠ **[#1113](https://github.com/pooza/capsicum/issues/1113) の「ガードは層
/// ごとに抜ける」の再発。**「呼ぶ側が思い出して関所を通す」形である限り、
/// **4 つ目が足されたときに同じことが起きる**。だから *持てないようにする*。
///
/// ## 何を違反とするか
///
/// **`FlutterSecureStorage` を名前に束ねたうえで、その名前を `.` で使うこと。**
/// ⚠ **「`FlutterSecureStorage` という語が出ること」を違反にはしない** ——
/// `SecureStorageGate(FlutterSecureStorage(…))` のように**その場で関所へ渡す**
/// 形は正しく、区画（accessibility / access group）は店ごとに違うので
/// **渡す側に書くしかない**（揃えると既存 item が見えなくなる・#392 / #643 / #656）。
///
/// ⚠ **名前に束ねただけは違反にしない。**`AccountStorage` の
/// `AccountStorage([FlutterSecureStorage? storage])` は**テストの差し替え口**で、
/// `storage` は関所へ渡すだけで `.` では使わない。**使った瞬間に落ちる。**

/// この名前は secure storage そのものを指す、と読める宣言を集める。
///
/// ⚠ **列挙をやめ、構造で見る**（`docs/CLAUDE.md`「判定を書くときの原則」）。
/// 変数名の表（`_storage` など）にすると、次に別名で足されたとき黙って通る。
Set<String> secureStorageBindings(String code) {
  final names = <String>{};
  // (a) 型として宣言した名前: `final FlutterSecureStorage _storage;` /
  //     `FlutterSecureStorage? storage` / `FlutterSecureStorage s = …`
  for (final m in RegExp(
    r'FlutterSecureStorage\s*\??\s+([A-Za-z_$][A-Za-z0-9_$]*)',
  ).allMatches(code)) {
    names.add(m.group(1)!);
  }
  // (b) 生成したものを名前へ束ねた形: `static const _storage = FlutterSecureStorage(`
  for (final m in RegExp(
    r'([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:const\s+)?FlutterSecureStorage\s*\(',
  ).allMatches(code)) {
    names.add(m.group(1)!);
  }
  return names;
}

/// 束ねた名前を `.` で使っている＝**関所を通らずに直に叩いている**。
///
/// ⚠ 呼ぶメソッド名（read / write / delete / readAll / containsKey）を列挙
/// しない。**次に増えたメソッドが黙って通る**ので、`.` そのものを見る。
List<String> directSecureStorageUses(String code) {
  final hits = <String>[];
  for (final name in secureStorageBindings(code)) {
    final uses = RegExp(
      '(?<![A-Za-z0-9_\$.])${RegExp.escape(name)}\\s*\\.',
    ).allMatches(code);
    if (uses.isNotEmpty) hits.add('$name (${uses.length} 箇所)');
  }
  return hits;
}

void main() {
  /// 関所の実体。ここだけは `FlutterSecureStorage` を名前で持ってよい。
  const gatePath = 'lib/src/service/secure_storage_gate.dart';

  /// secure storage を触る店。**関所へ委譲していること**まで見る
  /// （`docs/CLAUDE.md`「集約したものは委譲していることまで見る」）。
  const storePaths = [
    'lib/src/service/account_storage.dart',
    'lib/src/service/push_key_store.dart',
    'lib/src/service/device_install_id.dart',
  ];

  List<File> libFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  /// コメントと文字列を潰す。⚠ **文字列も潰す** —— import の
  /// `'package:flutter_secure_storage/flutter_secure_storage.dart'` は
  /// 文字列なので、潰さないと (a) が中の語に当たりうる。
  String normalize(String source) => maskStrings(maskComments(source));

  test('探索が空振りしていない', () {
    expect(libFiles().length, greaterThan(100));

    // ⚠ 関所が実在すること。ここが消えると下の検査は「対象なし」で緑になる。
    final gate = File(gatePath);
    expect(gate.existsSync(), isTrue, reason: '関所のファイルが無い');
    expect(
      normalize(gate.readAsStringSync()),
      contains('class SecureStorageGate'),
      reason: '関所の宣言が見つからない。検査のアンカーが外れている',
    );

    // ⚠⚠ **委譲していることを見る。**店が自前実装へ戻っても、関所のファイルは
    // 緑のまま残る（#1083-A の「集約の再発は使わなくなることとして現れる」）。
    for (final path in storePaths) {
      final code = normalize(File(path).readAsStringSync());
      expect(
        code,
        contains('SecureStorageGate'),
        reason: '$path が関所を通らなくなっている',
      );
    }

    // ⚠ 判定のアンカーそのものが実在すること。`FlutterSecureStorage` の語が
    // lib から消えたら、束縛を探す検査は「どちらも無い」で緑になる。
    final mentioning = libFiles()
        .where(
          (f) => normalize(f.readAsStringSync()).contains('FlutterSecureStorage'),
        )
        .toList();
    expect(
      mentioning,
      hasLength(greaterThanOrEqualTo(4)),
      reason: '関所 + 店 3 つで最低 4 ファイル。走査が届いていない',
    );
  });

  test('関所の外で secure storage を名前で握って直に叩いていない (#1136)', () {
    final offenders = <String>[];
    for (final file in libFiles()) {
      if (file.path.endsWith('secure_storage_gate.dart')) continue;
      final uses = directSecureStorageUses(normalize(file.readAsStringSync()));
      if (uses.isNotEmpty) offenders.add('${file.path}: ${uses.join(', ')}');
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'secure storage を関所 (SecureStorageGate) を通さずに直に叩いている。'
          'キーリングが応答しない Linux では、この呼び出しが'
          'プラットフォームスレッド（＝描くスレッド）を塞いで画面が固まる'
          '\n${offenders.join('\n')}',
    );
  });

  group('走査に歯がある', () {
    test('合成したソースで当たるべき形に当たる', () {
      // 型で宣言して直に叩く（修正前の AccountStorage の形）。
      expect(
        directSecureStorageUses('''
final FlutterSecureStorage _storage;
Future<String?> read(String k) => _storage.read(key: k);
'''),
        isNotEmpty,
      );
      // 生成を名前へ束ねて直に叩く（修正前の PushKeyStore / DeviceInstallId）。
      expect(
        directSecureStorageUses('''
static const _storage = FlutterSecureStorage();
static Future<void> delete(String k) => _storage.delete(key: k);
'''),
        isNotEmpty,
      );
      // ⚠ **メソッド名を列挙していないので、新しいメソッドでも当たる。**
      expect(
        directSecureStorageUses('''
static const _box = FlutterSecureStorage();
static Future<void> f() => _box.somethingBrandNew();
'''),
        isNotEmpty,
      );
    });

    test('当ててはいけない形に当たらない', () {
      // その場で関所へ渡す（名前に束ねない）＝正しい形。
      expect(
        directSecureStorageUses('''
static const _gate = SecureStorageGate(
  FlutterSecureStorage(iOptions: IOSOptions()),
);
static Future<void> f() => _gate.delete(key: 'x');
'''),
        isEmpty,
      );
      // 差し替え口として受け取り、関所へ渡すだけ（`.` で使わない）。
      expect(
        directSecureStorageUses('''
AccountStorage([FlutterSecureStorage? storage])
  : _gate = SecureStorageGate(storage ?? const FlutterSecureStorage());
'''),
        isEmpty,
      );
      // ⚠ **同じ語で終わる別の名前を receiver と読まない。**
      expect(
        directSecureStorageUses('''
static const _storage = FlutterSecureStorage();
static Future<void> f() => other_storage.read(key: 'x');
'''),
        isEmpty,
      );
      // コメント / 文字列の中の記述は対象外（normalize 後に見る前提）。
      expect(
        directSecureStorageUses(
          normalize('''
// final FlutterSecureStorage _storage = …; _storage.read(key: k);
const doc = 'FlutterSecureStorage _storage; _storage.read(key: k)';
'''),
        ),
        isEmpty,
      );
    });

    // ⚠⚠ **修正前のソースを実際に食わせる（3 点セットの 3）。**合成ソースは
    // 「自分が想定した書き方」しか並べられない。#1062 のガード初版はそれで
    // **修正対象の実物を拾えていなかった**。
    test('⚠⚠ 修正前の 3 ファイルは全部当たる', () {
      // #1136 を直す直前の develop。
      const preFix = '95645329';
      for (final path in storePaths) {
        final shown = Process.runSync('git', [
          '-C',
          '../..',
          'show',
          '$preFix:packages/capsicum/$path',
        ]);
        if (shown.exitCode != 0) {
          markTestSkipped('git show が使えない: ${shown.stderr}');
          return;
        }
        expect(
          directSecureStorageUses(normalize(shown.stdout as String)),
          isNotEmpty,
          reason: '修正前の $path は secure storage を直に叩いていたはず',
        );
      }
    });

    test('⚠ 修正前の 3 ファイルには関所への委譲が無い', () {
      const preFix = '95645329';
      for (final path in storePaths) {
        final shown = Process.runSync('git', [
          '-C',
          '../..',
          'show',
          '$preFix:packages/capsicum/$path',
        ]);
        if (shown.exitCode != 0) {
          markTestSkipped('git show が使えない: ${shown.stderr}');
          return;
        }
        expect(
          normalize(shown.stdout as String),
          isNot(contains('SecureStorageGate')),
          reason: '修正前に関所があったことになっている。アンカーの取り違え',
        );
      }
    });
  });
}
