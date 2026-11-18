import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1394: キーリングの作成をはさむログインで、保存の失敗のあと**同じ起動の
/// うちに**試し直せることの検査。
///
/// キーリングがまだ無い Linux では、最初の保存で OS のキーリングの作成の画面が
/// 出る。作成を待つあいだに関所の上限で打ち切られると、2 つの状態が残って
/// 起動し直すまで戻らなかった。
///
/// 1. `SecretServiceProbe` が「応答しない」と覚え、以降は触る前に諦める。
///    捨てるのはオフラインの再試行の 1 周だけだった
/// 2. `_finishLogin` が先頭で立てる `_loginCompleted` が立ったまま残り、
///    次に押しても `_login` の 1 行目で黙って抜ける
///
/// ⚠ **widget test にできない。**どちらも private な State の中で、本物の
/// OAuth の往復とキーリングの打ち切りを通らないと到達しない。順序の問題なので
/// `offline_retry_action_gate_source_test.dart` と同じくソースで固定する。
void main() {
  const path = 'lib/src/ui/screen/login_screen.dart';
  String masked() => maskStrings(maskComments(File(path).readAsStringSync()));

  const loginSignature = 'Future<void> _login(';
  const finishSignature = 'Future<void> _finishLogin(';
  const forget = 'SecretServiceProbe.forgetUnresponsive()';
  const fallbackSignatures = [
    'Future<bool> _tryMiAuthFallback(',
    'Future<bool> _tryManualCodeFallback(',
  ];
  const releaseSignature = 'bool _releaseAfterFallbackFailure(';
  const releaseCall = '_releaseAfterFallbackFailure()';

  group('探索が空振りしていない', () {
    test('対象のメソッドが見つかる', () {
      expect(File(path).existsSync(), isTrue);
      final source = masked();
      for (final signature in [
        loginSignature,
        finishSignature,
        ...fallbackSignatures,
        releaseSignature,
      ]) {
        final body = methodBody(source, signature);
        expect(body, isNotEmpty, reason: '$signature のシグネチャが変わった。検査も直す');
      }
    });

    test('目印にしている呼び出しが本体の中に実在する', () {
      final login = methodBody(masked(), loginSignature);
      expect(login, contains('getHostClientCredentials('));
      expect(login, contains('classifyLoginFailure(e)'));
      expect(login, contains('!_loginCompleted && adapter != null'));
      final finish = methodBody(masked(), finishSignature);
      expect(finish, contains('saveHostClientCredentials('));
      expect(finish, contains('addAccount('));
      for (final signature in fallbackSignatures) {
        final body = methodBody(masked(), signature);
        expect(body, contains('_finishLogin('), reason: signature);
        expect(body, contains('catch ('), reason: signature);
      }
    });
  });

  group('判定（合成ソース）', () {
    test('本体の切り出し: 名前付き引数の波括弧を本体と取り違えない', () {
      const source =
          'Future<void> _login({bool isRetry = false}) async '
          '{ if (x) { a(); } b(); } void other() { c(); }';
      final body = methodBody(source, loginSignature);
      expect(body, contains('b();'));
      expect(body, isNot(contains('isRetry')));
      expect(body, isNot(contains('c();')));
    });

    test('記憶を捨てる位置: 保存より前なら当たり・後なら外れ', () {
      expect(isBefore('{ $forget; save(); }', forget, 'save('), isTrue);
      expect(isBefore('{ save(); $forget; }', forget, 'save('), isFalse);
      expect(isBefore('{ save(); }', forget, 'save('), isFalse);
    });

    test('⚠ コメントの中の呼び出しは数えない', () {
      final source = maskStrings(maskComments('{ // $forget\n save(); }'));
      expect(isBefore(source, forget, 'save('), isFalse);
    });

    test('catch の中の呼び出し: catch の中なら当たり・try の中や無しは外れ', () {
      expect(
        callsInLastCatch(
          '{ try { a(); } catch (e) { $releaseCall; } }',
          releaseCall,
        ),
        isTrue,
      );
      expect(
        callsInLastCatch(
          '{ try { $releaseCall; } catch (e) { b(); } }',
          releaseCall,
        ),
        isFalse,
      );
      expect(callsInLastCatch('{ a(); $releaseCall; }', releaseCall), isFalse);
      final commented = maskStrings(
        maskComments('{ try { a(); } catch (e) { // $releaseCall\n } }'),
      );
      expect(callsInLastCatch(commented, releaseCall), isFalse);
    });
  });

  group('#1394', () {
    test('押した試行では、最初に触る前に「応答しない」の記憶を捨てる', () {
      expect(
        isBefore(
          methodBody(masked(), loginSignature),
          forget,
          'getHostClientCredentials(',
        ),
        isTrue,
        reason:
            'キーリングの作成を待つあいだに打ち切られると、起動し直すまで'
            '保存を試さない（#1394 の 2）',
      );
    });

    test('トークンの保存の直前にも記憶を捨てる', () {
      final finish = methodBody(masked(), finishSignature);
      expect(
        isBefore(finish, forget, 'saveHostClientCredentials('),
        isTrue,
        reason:
            'ブラウザで認可しているあいだにキーリングを作っても、'
            'トークンを手にしたまま保存を試さずに失敗する',
      );
      expect(isBefore(finish, forget, 'addAccount('), isTrue);
    });

    test('保存に失敗したら、もう一度押せるように _loginCompleted を戻す', () {
      final login = methodBody(masked(), loginSignature);
      final reset = login.indexOf('_loginCompleted = false');
      expect(reset, isNot(-1), reason: '戻さないと、次に押しても _login の 1 行目で黙って抜ける');
      expect(
        reset,
        greaterThan(login.indexOf('!_loginCompleted && adapter != null')),
        reason:
            '手入力のフォールバックの判定より前に戻すと、保存の失敗で'
            '認可コードの入力を求めてしまう',
      );
      expect(
        reset,
        greaterThan(login.indexOf('classifyLoginFailure(e)')),
        reason: 'エラーを表示する分岐の中で戻す',
      );
    });

    test('フォールバックの中で保存に失敗しても、_loginCompleted を戻す', () {
      // ⚠ フォールバックは自前の catch で握るので、上の _login の分岐を通らない
      // （v2.13 のリリース前レビューで 2 観点が独立に指摘）。
      final source = masked();
      for (final signature in fallbackSignatures) {
        expect(
          callsInLastCatch(methodBody(source, signature), releaseCall),
          isTrue,
          reason: '$signature の catch で戻さないと、次に押しても黙って抜ける',
        );
      }
      expect(
        methodBody(source, releaseSignature),
        contains('_loginCompleted = false'),
      );
    });
  });
}

/// [body] の最後の `catch (` 以降に [call] があるか。
bool callsInLastCatch(String body, String call) {
  final at = body.lastIndexOf('catch (');
  return at >= 0 && body.indexOf(call, at) >= 0;
}

/// [signature] で始まるメソッドの本体（`{` から対応する `}` まで）。
///
/// ⚠ **引数リストの閉じ括弧の後から `{` を探す。**`_login({bool isRetry = false})`
/// のように名前付き引数を持つと、素朴に最初の `{` を取ると引数を本体と取り違える。
String methodBody(String code, String signature) {
  final start = code.indexOf(signature);
  if (start < 0) return '';
  final close = matchingCloseParen(code, start + signature.length - 1);
  if (close < 0) return '';
  final open = code.indexOf('{', close);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}' && --depth == 0) return code.substring(open, i + 1);
  }
  return '';
}

/// [body] の中で [first] が [then] より前に現れるか。どちらかが無ければ false。
bool isBefore(String body, String first, String then) {
  final a = body.indexOf(first);
  final b = body.indexOf(then);
  return a >= 0 && b >= 0 && a < b;
}
