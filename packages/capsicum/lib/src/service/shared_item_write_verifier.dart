import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../util/exception_scrub.dart';

/// 全キーが 1 つの保存項目に入る secure storage で、**書き損じを読み戻して直す**
/// (#1387)。使うのは `storesSecretsInSharedItem` が true の OS（Linux）だけ。
///
/// ## 何が起きるのか
///
/// `flutter_secure_storage_linux` は全キーを 1 つの JSON にまとめ、書き込みの
/// たびに「読む → 1 キー足す → 全体を書く」をする。gnome-keyring 50.0 の
/// パスワードなしのキーリングでは、この「全体を書く」が**ときどき空で保存
/// される**（200 回中 12 回・#1387）。すると次の書き込みは「空 + 1 キー」で
/// 上書きし、**ほかのアカウントのトークンと `client_creds_*` がまとめて消える。**
///
/// ## 直し方
///
/// 書き込み / 削除のあとに全体を読み戻し、**このプロセスが知っている中身**
/// （[_known]）と食い違うキーを書き直す。
///
/// - ⚠⚠ **書き直しの元は [_known] だけ。**読み戻した値を元にすると、空で保存
///   された状態をそのまま広げる。[_known] は「書き込みの前に読めた値」と
///   「このプロセスが書いた値」からしか作らない
/// - ⚠ **読み戻しの結果で [_known] を消さない。**「読み戻しに無い」は書き損じの
///   印であって、消えてよいという意味ではない。[_known] から消すのは削除の
///   ときだけ
/// - ⚠ **回数に上限を付ける**（[maxRewriteRounds]）。空で保存され続ける
///   キーリングで、書き込みのたびに書き直しが回り続けないように。上限で
///   諦めたら Sentry に **1 プロセス 1 回**だけ記録する（値もキーも送らない）
/// - ⚠ **書き直しの失敗で元の操作を失敗させない。**元の書き込みは成功して
///   いる。読み戻しに失敗したら、書き直しを諦めてログに残すだけにする
/// - ⚠ **書き込みは 1 本に並べる。**4 つの店（アカウント・push 鍵・
///   インストール ID・購入トークン）が同じ 1 項目を共有しているので、2 つの
///   読み戻しが互い違いに走ると、片方の書き直しがもう片方を消す
class SharedItemWriteVerifier {
  SharedItemWriteVerifier._();

  /// 4 店で共有する唯一の控え。⚠ 店ごとに持たない（保存項目が 1 つなので）。
  static final SharedItemWriteVerifier instance = SharedItemWriteVerifier._();

  /// 1 回の書き込みのあとに、読み戻して書き直す周回の上限。
  ///
  /// 空で保存される率は 6% ほど（#1387）。食い違うキーが数個なら、3 周で
  /// まず揃う。揃わないのは「ほぼ毎回空で保存される」環境で、そこで回し
  /// 続けても揃わない。
  static const int maxRewriteRounds = 3;

  /// このプロセスが「保存されているはず」と知っている中身。⚠ 値は secret。
  /// ログ・Sentry へ出さない。
  final Map<String, String> _known = {};

  /// 最初の書き込みの前に、全体を 1 回読んで [_known] を作ったか。
  ///
  /// ⚠ **これが無いと、起動してまだ何も読んでいないキーを守れない。**最初の
  /// 書き込みが空で保存されたとき、[_known] がそのキー 1 つしか知らないので、
  /// 「揃っている」と見なしてしまう。
  bool _primed = false;

  /// 書き込みを 1 本に並べるための末尾。
  Future<void> _tail = Future<void>.value();

  /// Sentry へ送ったか。⚠ **1 プロセス 1 回。**
  bool _reported = false;

  /// 書き直しを試みた回数（テストと手元の観測用）。
  @visibleForTesting
  int rewriteCount = 0;

  /// 読めた値を控える。⚠ **null（無い）では控えを消さない**（書き損じのあとの
  /// 「無い」かもしれないので）。
  void noteRead(String key, String? value) {
    if (value != null) _known[key] = value;
  }

  /// 全件読めた値を控える。⚠ **足すだけで、無いキーを控えから消さない。**
  void noteReadAll(Map<String, String> all) {
    _known.addAll(all);
  }

  /// 書き込み / 削除を 1 つ行い、そのあと読み戻して書き直す。
  ///
  /// [body] が投げたら控えを更新せずにそのまま投げる。[value] が null なら
  /// 削除（プラグインの `write(value: null)` と同じ意味）。
  Future<void> mutate({
    required String key,
    required String? value,
    required Future<void> Function() body,
    required Future<Map<String, String>> Function() readAll,
    required Future<void> Function(String key, String value) rewrite,
  }) {
    final run = _tail.then(
      (_) => _mutate(
        key: key,
        value: value,
        body: body,
        readAll: readAll,
        rewrite: rewrite,
      ),
    );
    // ⚠ 失敗しても後続を止めない（失敗は呼び出し側へ run で返る）。
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _mutate({
    required String key,
    required String? value,
    required Future<void> Function() body,
    required Future<Map<String, String>> Function() readAll,
    required Future<void> Function(String key, String value) rewrite,
  }) async {
    if (!_primed) {
      try {
        noteReadAll(await readAll());
        _primed = true;
      } catch (e) {
        // 読めないなら書き込みも多分通らない。控えを作らずに本体へ進み、
        // 失敗の扱いは本体の例外に任せる。次の書き込みでまた試す。
        debugLogException('capsicum: shared item prime failed', e);
      }
    }

    await body();
    if (value == null) {
      _known.remove(key);
    } else {
      _known[key] = value;
    }

    try {
      await _verify(readAll: readAll, rewrite: rewrite);
    } catch (e) {
      debugLogException('capsicum: shared item verify failed', e);
    }
  }

  Future<void> _verify({
    required Future<Map<String, String>> Function() readAll,
    required Future<void> Function(String key, String value) rewrite,
  }) async {
    for (var round = 0; ; round++) {
      final stored = await readAll();
      final lost = <String, String>{
        for (final entry in _known.entries)
          if (stored[entry.key] != entry.value) entry.key: entry.value,
      };
      if (lost.isEmpty) {
        if (round > 0) {
          debugPrint('capsicum: shared item restored after $round round(s)');
        }
        return;
      }
      if (round >= maxRewriteRounds) {
        _reportExhausted(lost.length);
        return;
      }
      debugPrint('capsicum: shared item lost ${lost.length} key(s); rewriting');
      for (final entry in lost.entries) {
        rewriteCount++;
        await rewrite(entry.key, entry.value);
      }
    }
  }

  void _reportExhausted(int lostCount) {
    debugPrint(
      'capsicum: shared item still missing $lostCount key(s) '
      'after $maxRewriteRounds rounds; giving up',
    );
    if (_reported) return;
    _reported = true;
    unawaited(
      Sentry.captureMessage(
        'secure_storage.shared_item_rewrite_exhausted',
        level: SentryLevel.warning,
        withScope: (scope) {
          // ⚠ キーの名前（ホスト名・アカウント）も値も載せない。知りたいのは
          // 「書き直しでも揃わない環境が実在するか」と、その規模だけ。
          scope.setContexts('secure_storage', {
            'lost_count': lostCount,
            'known_count': _known.length,
            'rounds': maxRewriteRounds,
          });
        },
      ),
    );
  }

  @visibleForTesting
  void resetForTest() {
    _known.clear();
    _primed = false;
    _tail = Future<void>.value();
    _reported = false;
    rewriteCount = 0;
  }

  @visibleForTesting
  bool get reportedForTest => _reported;
}
