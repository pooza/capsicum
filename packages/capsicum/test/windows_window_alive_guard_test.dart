import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1248: Windows の runner で、`OnDestroy` が倒した `window_alive` を
/// `OnCreate` が必ず立て直していること。
///
/// 🔴 **立て直していなかったので、Windows の投げ銭は #795 から 2.0.1 まで
/// 1 度も商品を出せていなかった。**`Win32Window::Create` はウィンドウを作る前に
/// 必ず `Destroy()` → `OnDestroy()` を通る（Flutter のテンプレートの作り）。
/// `OnDestroy` は「破棄後のワーカーに結果を書かせない」ために `window_alive` を
/// false にするが、`OnCreate` が `hwnd` しか入れ直さなかったので、**プロセスの
/// 寿命を通して「破棄済み」のまま**だった。Store は 1 秒で商品を返していたのに、
/// ワーカーが結果を捨て、Dart は返事を永久に待っていた。
///
/// ⚠ **`.cpp` を読むのは、C++ 側のテストが tag ビルドでしか回らないため**
/// （`wns_benign_codes_parity_test.dart` と同じ理由）。しかもこの不具合は
/// 「ウィンドウの作られ方」に依るので、状態だけを切り出した単体テストでは
/// 再現しない。
///
/// ⚠ **関数の形が変わったら落ちる**（`bool FlutterWindow::OnCreate() {` /
/// `void FlutterWindow::OnDestroy() {` を前提にしている）。落ちたら「壊れた」
/// ではなく「検査を作り直せ」の合図。
void main() {
  /// [signature] で始まる関数の本体（コメントは空白へ潰してある）。
  String functionBody(String masked, String signature) {
    final start = masked.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature が見つからない（改名した？）');
    // 関数の終端は、行頭の `}`。
    final end = masked.indexOf('\n}', start);
    expect(end, isNot(-1), reason: '$signature の終端が見つからない');
    return masked.substring(start, end);
  }

  /// `OnDestroy` が `window_alive = false` にする共有状態の名前。
  Set<String> statesClearedOnDestroy(String source) {
    final body = functionBody(
      maskComments(source),
      'void FlutterWindow::OnDestroy() {',
    );
    return RegExp(
      r'(\w+)->window_alive\s*=\s*false\s*;',
    ).allMatches(body).map((m) => m.group(1)!).toSet();
  }

  /// `OnDestroy` が倒したのに、`OnCreate` が立て直していない共有状態。
  Set<String> statesNotRevived(String source) {
    final body = functionBody(
      maskComments(source),
      'bool FlutterWindow::OnCreate() {',
    );
    final revived = RegExp(
      r'(\w+)->window_alive\s*=\s*true\s*;',
    ).allMatches(body).map((m) => m.group(1)!).toSet();
    return statesClearedOnDestroy(source).difference(revived);
  }

  String runnerSource() =>
      File('windows/runner/flutter_window.cpp').readAsStringSync();

  test('OnDestroy が倒した window_alive を、OnCreate がすべて立て直している', () {
    expect(
      statesNotRevived(runnerSource()),
      isEmpty,
      reason:
          'Win32Window::Create は作る前に OnDestroy を通る。立て直さないと、'
          'ワーカーが結果を毎回捨てる (#1248)',
    );
  });

  /// `OnDestroy` から 1 件も拾えていなければ、上は何も見ずに通る。
  test('走査が空振りしていない', () {
    expect(
      statesClearedOnDestroy(runnerSource()),
      containsAll(<String>['store_state_', 'dedup_state_']),
    );
  });

  group('判定', () {
    String source({required String onCreate}) =>
        '''
bool FlutterWindow::OnCreate() {
$onCreate
  return true;
}

void FlutterWindow::OnDestroy() {
  {
    std::lock_guard<std::mutex> lock(store_state_->mutex);
    store_state_->window_alive = false;
    store_state_->hwnd = nullptr;
  }
}
''';

    test('立て直していれば通す', () {
      expect(
        statesNotRevived(
          source(
            onCreate: '''
  store_state_->window_alive = true;
  store_state_->hwnd = GetHandle();''',
          ),
        ),
        isEmpty,
      );
    });

    test('hwnd だけ入れ直す形（2.0.1 までの実物）を拾う', () {
      expect(
        statesNotRevived(
          source(onCreate: '  store_state_->hwnd = GetHandle();'),
        ),
        {'store_state_'},
      );
    });

    test('コメントの中の代入は、立て直したことにしない', () {
      expect(
        statesNotRevived(
          source(
            onCreate: '''
  // store_state_->window_alive = true;
  store_state_->hwnd = GetHandle();''',
          ),
        ),
        {'store_state_'},
      );
    });

    test('別の状態を立て直しても、倒した状態の代わりにならない', () {
      expect(
        statesNotRevived(
          source(
            onCreate: '''
  dedup_state_->window_alive = true;
  store_state_->hwnd = GetHandle();''',
          ),
        ),
        {'store_state_'},
      );
    });
  });
}
