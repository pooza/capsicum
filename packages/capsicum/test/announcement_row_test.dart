import 'package:capsicum/src/ui/screen/settings/push_notification_settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 設定画面「プッシュ通知」のアカウント行に、お知らせ通知の何を出すか (#919)。
///
/// macOS が relay の配送対象に入った (capsicum-relay#36 Phase 1) ことで、
/// この判定は「mobile か否か」から「relay が配るか否か」に変わった。配らない
/// プラットフォームでは黙るのではなく「起動中のみ届く」と説明する。
void main() {
  group('購読できるプラットフォーム (iOS / Android / macOS)', () {
    test('registered ならトグルを出す', () {
      expect(
        resolveAnnouncementRow(
          platformSupported: true,
          serverSupported: true,
          registered: true,
          hasLocalState: false,
        ),
        AnnouncementRowKind.toggle,
      );
    });

    // register snapshot が idle / failed に落ちていても、relay 側の
    // subscription は生きている。OFF にする導線を残す。
    test('registered でなくてもローカル状態があればトグルを出す', () {
      expect(
        resolveAnnouncementRow(
          platformSupported: true,
          serverSupported: true,
          registered: false,
          hasLocalState: true,
        ),
        AnnouncementRowKind.toggle,
      );
    });

    test('registered でもローカル状態でもなければ出さない', () {
      expect(
        resolveAnnouncementRow(
          platformSupported: true,
          serverSupported: true,
          registered: false,
          hasLocalState: false,
        ),
        AnnouncementRowKind.none,
      );
    });

    // 説明は「購読できないから起動中だけ」という話なので、購読できる環境で
    // 出すと嘘になる。
    test('説明は出さない', () {
      for (final registered in [true, false]) {
        for (final hasLocalState in [true, false]) {
          expect(
            resolveAnnouncementRow(
              platformSupported: true,
              serverSupported: true,
              registered: registered,
              hasLocalState: hasLocalState,
            ),
            isNot(AnnouncementRowKind.runningOnlyNote),
            reason: 'registered=$registered hasLocalState=$hasLocalState',
          );
        }
      }
    });
  });

  group('購読できないプラットフォーム (Windows / Linux)', () {
    // #919 の発端。トグルが無い理由と、取りこぼしの回収先を書く。
    test('registered でも説明を出す (トグルは出さない)', () {
      expect(
        resolveAnnouncementRow(
          platformSupported: false,
          serverSupported: true,
          registered: true,
          hasLocalState: false,
        ),
        AnnouncementRowKind.runningOnlyNote,
      );
    });

    // 説明は登録状況と無関係の事実なので、未登録でも出す。
    test('未登録でも説明を出す', () {
      expect(
        resolveAnnouncementRow(
          platformSupported: false,
          serverSupported: true,
          registered: false,
          hasLocalState: false,
        ),
        AnnouncementRowKind.runningOnlyNote,
      );
    });

    // 死に subscription が残っていても、OFF にするトグルは出さない
    // (autoEnableIfDefault が片付ける経路なので UI で触らせる必要が無い)。
    test('ローカル状態が残っていてもトグルにはしない', () {
      expect(
        resolveAnnouncementRow(
          platformSupported: false,
          serverSupported: true,
          registered: true,
          hasLocalState: true,
        ),
        AnnouncementRowKind.runningOnlyNote,
      );
    });
  });

  group('お知らせ push 非対応サーバー', () {
    // relay はモロヘイヤの公開キャッシュを polling するので、
    // features.announcement_push が無いサーバーには push 自体が存在しない。
    // ここで説明を出すと無関係の不安を煽る。
    test('購読できるプラットフォームでも出さない', () {
      expect(
        resolveAnnouncementRow(
          platformSupported: true,
          serverSupported: false,
          registered: true,
          hasLocalState: true,
        ),
        AnnouncementRowKind.none,
      );
    });

    test('購読できないプラットフォームでも説明を出さない', () {
      expect(
        resolveAnnouncementRow(
          platformSupported: false,
          serverSupported: false,
          registered: true,
          hasLocalState: true,
        ),
        AnnouncementRowKind.none,
      );
    });
  });
}
