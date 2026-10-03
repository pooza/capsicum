import 'package:capsicum/src/service/resident_mode_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// トレイのバージョン表記 (#1154)。
///
/// ⚠⚠ **この検査の主題は「debug と release が見分けられること」。**version /
/// buildNumber を出すだけなら両者は同じ文字列になり、**要望（複数起動したときに
/// どのビルドか分からない）が満たせないまま「バージョンは出ている」になる。**
void main() {
  group('trayVersionLabel', () {
    test('release ビルドは印を付けない', () {
      expect(
        trayVersionLabel(
          version: '2.0.0',
          buildNumber: '186',
          isDebug: false,
          isProfile: false,
        ),
        'v2.0.0 (186)',
      );
    });

    test('⚠ debug ビルドは [debug] が付く（release と同じ文字列にならない）', () {
      const version = '2.0.0';
      const buildNumber = '186';
      final debug = trayVersionLabel(
        version: version,
        buildNumber: buildNumber,
        isDebug: true,
        isProfile: false,
      );
      final release = trayVersionLabel(
        version: version,
        buildNumber: buildNumber,
        isDebug: false,
        isProfile: false,
      );

      expect(debug, 'v2.0.0 (186) [debug]');
      // ⚠ 要望の本体はここ。同じ版を debug / release で同時に起動しても違う。
      expect(debug, isNot(release));
    });

    test('profile ビルドは [profile] が付く', () {
      expect(
        trayVersionLabel(
          version: '2.0.0',
          buildNumber: '186',
          isDebug: false,
          isProfile: true,
        ),
        'v2.0.0 (186) [profile]',
      );
    });

    test('debug と profile が同時に真なら debug を優先する', () {
      expect(
        trayVersionLabel(
          version: '2.0.0',
          buildNumber: '186',
          isDebug: true,
          isProfile: true,
        ),
        'v2.0.0 (186) [debug]',
      );
    });
  });
}
