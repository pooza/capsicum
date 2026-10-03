/// #1191: 解析 SDK（Firebase Analytics / GoogleAppMeasurement 系）が依存集合へ
/// 入ったら落とす。
///
/// ## なぜ要るか
///
/// 2026-09-30、Google Analytics for Firebase（iOS の `GoogleAppMeasurement`）の
/// 不具合で数千規模の iOS アプリが起動直後にクラッシュした。**capsicum は無影響
/// だった**が、それは**発火経路が製品内に無かったから**で、守られていたわけでは
/// ない（依存は `firebase_core` / `firebase_messaging` だけ・iOS の通知は自前
/// relay → APNs 直結）。
///
/// ⚠⚠ **放っておけば次の依存追加で黙って消える優位。**この検査は、その性質を
/// **仕様として固定する**ためにある。
///
/// ⚠ **「解析を将来も一切入れない」という決定ではない。**入れるなら意識的に
/// 入れる（このガードを外す判断をする）ための仕掛け。
///
/// ## 見る対象
///
/// 1. **`pubspec.lock`（リポジトリルート・追跡対象）** — 実質の関門。
///    `GoogleAppMeasurement` は Flutter プラグイン経由でしか入らないので、
///    解決済みパッケージ名の集合を見れば足りる（transitive も入る）
/// 2. **`android/build.gradle.kts` / `android/app/build.gradle.kts`** — gradle へ
///    直接 `firebase-analytics` / `play-services-measurement` を足す経路
///
/// ⚠ **`ios/Podfile.lock` と `ios/Pods/` は見ない。**どちらも gitignore 済みで
/// 追跡対象外のため、CI では存在が保証されない。
///
/// ## 判定
///
/// ⚠ **列挙をやめ、構造で見る**（`docs/CLAUDE.md`「ソース検査ガードの書き方」）。
/// 禁止パッケージ名の表ではなく、**識別子を `_` / `-` で切った成分**に
/// `analytics` / `measurement` があるかで見る。`firebase_analytics` /
/// `google_analytics` / `firebase-analytics` / `play-services-measurement` は
/// これで当たり、**次に増えた名前も自動で対象になる**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `pubspec.lock` の `packages:` 直下のキー（＝解決済みパッケージ名）。
///
/// ⚠ **2 スペースのキーだけを見る。**`description:` の中の `name:` や `url:`
/// （6 スペース）を拾うと、`url: "https://…analytics…"` のような無関係な文字列で
/// 誤検出する。
List<String> lockedPackageNames(String lock) {
  final out = <String>[];
  var inPackages = false;
  for (final line in lock.split('\n')) {
    if (line.isEmpty) continue;
    if (!line.startsWith(' ')) {
      inPackages = line.trimRight() == 'packages:';
      continue;
    }
    if (!inPackages) continue;
    final m = RegExp(r'^ {2}([A-Za-z0-9_]+):\s*$').firstMatch(line);
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

/// 解析 SDK を指す識別子か。
///
/// ⚠ **成分の一致で見る。**部分一致にすると `measurements`（単位換算）のような
/// 無関係な名前まで当たる。成分で見れば `firebase_analytics_web` は当たり、
/// `measurements` は当たらない。
bool isAnalyticsIdentifier(String name) => name
    .toLowerCase()
    .split(RegExp(r'[_\-.]'))
    .any((part) => part == 'analytics' || part == 'measurement');

/// gradle の依存座標（`group:artifact[:version]`）のうち、解析 SDK を指すもの。
///
/// ⚠ **コメント行は落とす。**「入れない」と書いた注記で落ちてはいけない。
/// ⚠ **座標の形だけを見る。**`:` を含まない素の文字列（説明文）は対象外。
List<String> analyticsGradleDependencies(String gradle) {
  final out = <String>[];
  for (final raw in gradle.split('\n')) {
    final line = raw.replaceFirst(RegExp(r'(//|#).*$'), '');
    for (final m in RegExp(
      r'"([A-Za-z0-9_.\-]+:[A-Za-z0-9_.\-]+(?::[^"]*)?)"',
    ).allMatches(line)) {
      final coordinate = m.group(1)!;
      final artifact = coordinate.split(':')[1];
      if (isAnalyticsIdentifier(artifact)) out.add(coordinate);
    }
  }
  return out;
}

void main() {
  // ⚠ テストの cwd は `packages/capsicum`。リポジトリルートはその 2 つ上。
  const repoRoot = '../..';
  const lockPath = '$repoRoot/pubspec.lock';
  const gradlePaths = [
    'android/build.gradle.kts',
    'android/app/build.gradle.kts',
  ];

  String read(String path) => File(path).readAsStringSync();

  group('1. 走査が空振りしていない', () {
    test('pubspec.lock を読めていて、解決済みパッケージを列挙できている', () {
      // ⚠⚠ 「禁止名が無い」だけを見ると、**ファイルを読めていなくても緑になる**。
      expect(File(lockPath).existsSync(), isTrue, reason: '$lockPath が無い');
      final names = lockedPackageNames(read(lockPath));
      expect(names.length, greaterThan(100), reason: 'lock を解釈できていない');
      // 既知のパッケージが列挙に入っていること。
      expect(names, containsAll(['firebase_core', 'firebase_messaging']));
    });

    test('gradle を読めていて、依存座標を取り出せている', () {
      for (final path in gradlePaths) {
        expect(File(path).existsSync(), isTrue, reason: '$path が無い');
      }
      // ⚠ 座標の取り出しが動いていることを、実在する 1 件で固定する
      // （`coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:…")`）。
      final coordinates = RegExp(
        r'"([A-Za-z0-9_.\-]+:[A-Za-z0-9_.\-]+(?::[^"]*)?)"',
      ).allMatches(read('android/app/build.gradle.kts')).map((m) => m.group(1));
      expect(
        coordinates.where((c) => c!.contains('desugar_jdk_libs')),
        isNotEmpty,
        reason: 'gradle の依存座標を取り出せていない。書き方が変わったらこの検査も直す',
      );
    });

    test('⚠ iOS 側は走査対象に入れていない', () {
      // `ios/Podfile.lock` / `ios/Pods/` は gitignore 済みで、CI では存在が
      // 保証されない。**存在しないものを見ると「読めなくても緑」になる**ので、
      // 走査対象に入っていないことを固定する。足すなら gitignore の扱いから
      // 見直すこと。
      expect(
        [...gradlePaths, lockPath].where((p) => p.contains('ios/')),
        isEmpty,
      );
    });
  });

  group('2. 判定ロジックに合成を食わせる', () {
    test('当たるべき名前', () {
      expect(isAnalyticsIdentifier('firebase_analytics'), isTrue);
      expect(isAnalyticsIdentifier('google_analytics'), isTrue);
      expect(isAnalyticsIdentifier('firebase_analytics_web'), isTrue);
      expect(isAnalyticsIdentifier('firebase-analytics'), isTrue);
      expect(isAnalyticsIdentifier('play-services-measurement'), isTrue);
      expect(isAnalyticsIdentifier('play-services-measurement-api'), isTrue);
      // 大文字でも当たる（`GoogleAppMeasurement` は見ないが、gradle の座標に
      // 大文字が来ても取りこぼさない）。
      expect(isAnalyticsIdentifier('Firebase-Analytics'), isTrue);
    });

    test('当ててはいけない名前', () {
      // 実在する依存。⚠ 例外エラー収集は解析 SDK ではない。
      expect(isAnalyticsIdentifier('sentry_flutter'), isFalse);
      expect(isAnalyticsIdentifier('firebase_core'), isFalse);
      expect(isAnalyticsIdentifier('firebase_messaging'), isFalse);
      // ⚠ 成分が一致しないもの（部分一致にすると当たってしまう形）。
      expect(isAnalyticsIdentifier('measurements'), isFalse);
      expect(isAnalyticsIdentifier('canalytics'), isFalse);
    });

    test('lock のコメント・説明文では当たらない', () {
      const lock = '''
# firebase_analytics は使わない（#1191）
packages:
  firebase_core:
    dependency: transitive
    description:
      name: firebase_core
      url: "https://pub.dev/packages/firebase_analytics"
    source: hosted
    version: "3.15.2"
''';
      final names = lockedPackageNames(lock);
      expect(names, ['firebase_core']);
      expect(names.where(isAnalyticsIdentifier), isEmpty);
    });

    test('lock に解析 SDK があれば当たる', () {
      const lock = '''
packages:
  firebase_analytics:
    dependency: "direct main"
    source: hosted
    version: "11.0.0"
  google_analytics:
    dependency: transitive
    source: hosted
    version: "1.0.0"
''';
      expect(lockedPackageNames(lock).where(isAnalyticsIdentifier), [
        'firebase_analytics',
        'google_analytics',
      ]);
    });

    test('gradle の依存に解析 SDK があれば当たる', () {
      const gradle = '''
dependencies {
    implementation("com.google.firebase:firebase-analytics:22.1.0")
    implementation("com.google.android.gms:play-services-measurement-api")
    implementation("com.android.tools:desugar_jdk_libs:2.1.4")
}
''';
      expect(analyticsGradleDependencies(gradle), [
        'com.google.firebase:firebase-analytics:22.1.0',
        'com.google.android.gms:play-services-measurement-api',
      ]);
    });

    test('gradle のコメント・座標でない文字列では当たらない', () {
      const gradle = '''
dependencies {
    // firebase-analytics は入れない（#1191）。入れるならガードを外す判断をする
    # play-services-measurement も同じ
    val note = "firebase-analytics"
    implementation("com.android.tools:desugar_jdk_libs:2.1.4")
}
''';
      expect(analyticsGradleDependencies(gradle), isEmpty);
    });
  });

  group('3. ⚠⚠ 歯があること（実物に穴を開けて確かめる）', () {
    test('実物の lock へ firebase_analytics を注ぎ込むと、その 1 件だけが挙がる', () {
      final real = read(lockPath);
      expect(
        lockedPackageNames(real).where(isAnalyticsIdentifier),
        isEmpty,
        reason: '注ぎ込む前から違反がある',
      );

      // ⚠ `packages:` 直下へ実物と同じ形で足す。
      final holed = real.replaceFirst('packages:\n', '''
packages:
  firebase_analytics:
    dependency: "direct main"
    description:
      name: firebase_analytics
      url: "https://pub.dev"
    source: hosted
    version: "11.6.0"
''');
      expect(lockedPackageNames(holed).where(isAnalyticsIdentifier), [
        'firebase_analytics',
      ]);
      // 他のパッケージを巻き込んでいない（1 件増えただけ）。
      expect(
        lockedPackageNames(holed).length,
        lockedPackageNames(real).length + 1,
      );
    });

    test('実物の gradle へ implementation を足すと挙がる', () {
      const path = 'android/app/build.gradle.kts';
      final real = read(path);
      expect(analyticsGradleDependencies(real), isEmpty, reason: '足す前から違反がある');

      final holed = real.replaceFirst(
        'dependencies {',
        'dependencies {\n    implementation("com.google.firebase:firebase-analytics")',
      );
      expect(analyticsGradleDependencies(holed), [
        'com.google.firebase:firebase-analytics',
      ]);
    });
  });

  group('解析 SDK は依存集合に入っていない (#1191)', () {
    test('pubspec.lock に解析系のパッケージが無い', () {
      final offenders = lockedPackageNames(
        read(lockPath),
      ).where(isAnalyticsIdentifier).toList();
      expect(
        offenders,
        isEmpty,
        reason:
            '解析 SDK が依存集合に入った。⚠ iOS では GoogleAppMeasurement が入り、'
            '2026-09-30 の障害（設定データの形が壊れて起動直後にクラッシュ）の'
            '発火経路が製品内にできる。入れるなら意識的に入れる判断をして、'
            'この検査を外すこと'
            '\n${offenders.join('\n')}',
      );
    });

    test('android の gradle に解析系の依存が無い', () {
      final offenders = [
        for (final path in gradlePaths)
          for (final coordinate in analyticsGradleDependencies(read(path)))
            '$path: $coordinate',
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'gradle へ解析 SDK を直接足している (#1191)。'
            'pub の依存と違って pubspec.lock には現れないので、ここで見る'
            '\n${offenders.join('\n')}',
      );
    });
  });
}
