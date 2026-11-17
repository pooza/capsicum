import 'package:capsicum/src/ui/util/offline_account_display.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1393: オフラインホームの見出しと本文を、オフラインになった理由で出し分ける。
///
/// 以前は Secret Service が居ないとき、赤い枠だけが「ログイン情報を読み出せ
/// ません」と言い、見出しと本文は「接続できません」「端末がオフラインか、
/// サーバーが停止中の可能性」のままだった。原因が 2 つ並んで見える。
void main() {
  OfflineHomeCopy copy({
    bool allNeedLogin = false,
    bool anyRetrying = false,
    bool keyringUnavailable = false,
    bool keyringLocked = false,
  }) => offlineHomeCopy(
    allNeedLogin: allNeedLogin,
    anyRetrying: anyRetrying,
    keyringUnavailable: keyringUnavailable,
    keyringLocked: keyringLocked,
  );

  /// オフライン / サーバーを疑わせる言い方が混じっていないか。
  void expectNoNetworkBlame(OfflineHomeCopy c) {
    for (final text in [c.title, c.heading, c.body]) {
      expect(text, isNot(contains('オフライン')), reason: text);
      expect(text, isNot(contains('サーバー')), reason: text);
      expect(text, isNot(contains('接続')), reason: text);
    }
  }

  group('offlineHomeCopy', () {
    test('キーリングが原因でなければ、従来どおりオフラインの説明', () {
      final c = copy();
      expect(c.title, '接続できません');
      expect(c.body, contains('端末がオフラインか'));
      expect(copy(anyRetrying: true).heading, '接続中…');
    });

    test('⚠⚠ Secret Service が読めないときは、オフラインやサーバーを疑わせない', () {
      final c = copy(keyringUnavailable: true);
      expectNoNetworkBlame(c);
      expect(c.title, contains('ログイン情報を読み出せません'));
      expect(c.body, contains('自動で再試行'));
      expectNoNetworkBlame(copy(keyringUnavailable: true, anyRetrying: true));
    });

    test('ロック中は解除を促し、自動で戻るとは言わない (#1386)', () {
      final c = copy(keyringUnavailable: true, keyringLocked: true);
      expectNoNetworkBlame(c);
      expect(c.title, contains('ロック'));
      expect(c.body, contains('解除すると'));
      expect(c.body, isNot(contains('自動')));
    });

    test('⚠ ロックの旗だけ残っていても、読めているならキーリングのせいにしない', () {
      // `markLocked(false)` は notifier を下ろさないが、逆に unavailable が
      // 下りて locked だけ残る形を作っても、オフラインの説明に戻ること。
      expect(copy(keyringLocked: true).title, '接続できません');
    });

    test('全件が未接続なら、キーリングより接続し直しを優先する (#967)', () {
      for (final keyring in [false, true]) {
        final c = copy(allNeedLogin: true, keyringUnavailable: keyring);
        expect(c.title, '未接続のアカウント');
        expect(c.body, contains('接続し直せば'));
      }
    });
  });

  group('offlineAccountSubtitle', () {
    test('キーリングが原因でなければ、従来どおり', () {
      expect(
        offlineAccountSubtitle(
          retrying: false,
          keyringUnavailable: false,
          keyringLocked: false,
        ),
        '接続を待っています',
      );
      expect(
        offlineAccountSubtitle(
          retrying: true,
          keyringUnavailable: false,
          keyringLocked: false,
        ),
        '再試行中…',
      );
    });

    test('キーリングが原因なら「接続を待っています」と言わない', () {
      final text = offlineAccountSubtitle(
        retrying: false,
        keyringUnavailable: true,
        keyringLocked: false,
      );
      expect(text, isNot(contains('接続')));
      expect(text, contains('読み出し'));
    });

    test('ロック中は再試行中とも言わない（自動の再試行は読まない）', () {
      expect(
        offlineAccountSubtitle(
          retrying: true,
          keyringUnavailable: true,
          keyringLocked: true,
        ),
        'キーリングの解除を待っています',
      );
    });
  });
}
