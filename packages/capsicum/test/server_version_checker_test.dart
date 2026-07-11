import 'package:capsicum/src/service/server_version_checker.dart';
import 'package:flutter_test/flutter_test.dart';

/// #815 続き: サーバーの運用版が本家 latest に追いついているかの判定。
/// フォーク suffix を落とした base 比較が、実データ（misskey.io / md.korako.me /
/// 美食丼 等）で正しく「古い/最新」を出すことを検証する。
void main() {
  group('ServerVersionChecker.baseVersion — フォーク suffix / build を落とす', () {
    test('Misskey フォーク suffix (-io.x-hash) を落とす', () {
      expect(
        ServerVersionChecker.baseVersion('2025.4.1-io.12b-fb6fbea074'),
        '2025.4.1',
      );
    });

    test('先頭 v・build 番号 (+N) を落とす', () {
      expect(ServerVersionChecker.baseVersion('v4.6.3'), '4.6.3');
      expect(ServerVersionChecker.baseVersion('2026.6.0+0'), '2026.6.0');
    });

    test('素の semver / 日付版はそのまま', () {
      expect(ServerVersionChecker.baseVersion('4.5.13'), '4.5.13');
      expect(ServerVersionChecker.baseVersion('2026.6.0'), '2026.6.0');
    });
  });

  group('ServerVersionChecker.isBehind — 本家 latest との比較', () {
    test('misskey.io (2025.4.1-io) は本家 2026.6.0 より古い', () {
      expect(
        ServerVersionChecker.isBehind('2025.4.1-io.12b-fb6fbea074', '2026.6.0'),
        isTrue,
      );
    });

    test('md.korako.me (4.5.13) は本家 4.6.3 より古い', () {
      expect(ServerVersionChecker.isBehind('4.5.13', '4.6.3'), isTrue);
    });

    test('美食丼 (4.6.3) / デルムリン (2026.6.0+0) は最新（古くない）', () {
      expect(ServerVersionChecker.isBehind('4.6.3', '4.6.3'), isFalse);
      expect(ServerVersionChecker.isBehind('2026.6.0+0', '2026.6.0'), isFalse);
    });

    test('本家より新しければ古くない（false）', () {
      expect(ServerVersionChecker.isBehind('4.7.0', '4.6.3'), isFalse);
      expect(ServerVersionChecker.isBehind('2026.7.0', '2026.6.0'), isFalse);
    });

    test('patch 1 つ遅れも古い', () {
      expect(ServerVersionChecker.isBehind('4.6.2', '4.6.3'), isTrue);
    });

    test('桁数違いは欠けた桁を 0 とみなす', () {
      expect(
        ServerVersionChecker.isBehind('4.6', '4.6.3'),
        isTrue,
      ); // 4.6.0<4.6.3
      expect(
        ServerVersionChecker.isBehind('4.6.3', '4.6'),
        isFalse,
      ); // 4.6.3>4.6.0
    });
  });

  group('ServerVersionChecker.isAtLeast — 機能ゲート (#810 Collections=4.6)', () {
    test('4.6.0 以上を満たす（等号含む・フォーク suffix / patch 上）', () {
      expect(ServerVersionChecker.isAtLeast('4.6.0', '4.6.0'), isTrue);
      expect(ServerVersionChecker.isAtLeast('4.6.3', '4.6.0'), isTrue);
      expect(
        ServerVersionChecker.isAtLeast('4.6.3-bshockdon', '4.6.0'),
        isTrue,
      );
      expect(ServerVersionChecker.isAtLeast('4.7.0', '4.6.0'), isTrue);
      expect(ServerVersionChecker.isAtLeast('5.0.0', '4.6.0'), isTrue);
    });

    test('4.6.0 未満は満たさない', () {
      expect(ServerVersionChecker.isAtLeast('4.5.13', '4.6.0'), isFalse);
      expect(ServerVersionChecker.isAtLeast('4.5.13-glitch', '4.6.0'), isFalse);
      expect(ServerVersionChecker.isAtLeast('3.5.0', '4.6.0'), isFalse);
    });

    test('桁数違いは欠けた桁を 0 とみなす', () {
      expect(ServerVersionChecker.isAtLeast('4.6', '4.6.0'), isTrue); // 4.6.0
      expect(ServerVersionChecker.isAtLeast('4.6', '4.6.1'), isFalse); // 4.6.0
    });

    test('数値でない版は minimum 未満扱い（0 に倒れる）', () {
      expect(ServerVersionChecker.isAtLeast('Glitch', '4.6.0'), isFalse);
      expect(ServerVersionChecker.isAtLeast('', '4.6.0'), isFalse);
    });

    test('isBehind とは補集合の関係（境界含む）', () {
      expect(ServerVersionChecker.isAtLeast('4.6.3', '4.6.3'), isTrue);
      expect(ServerVersionChecker.isBehind('4.6.3', '4.6.3'), isFalse);
      expect(ServerVersionChecker.isAtLeast('4.5.0', '4.6.0'), isFalse);
      expect(ServerVersionChecker.isBehind('4.5.0', '4.6.0'), isTrue);
    });
  });
}
