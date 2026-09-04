import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #1076: 本人が「出さない」と設定したプロフィールの要素を capsicum が
/// 出していないことを固定する。
///
/// ## なぜ検査が要るか
///
/// ⚠⚠ **タブの出し分けはサーバーに止めようがない。**`show_media` /
/// `show_media_replies` / `show_featured` / `hide_collections` は
/// **描画の話**なので、サーバー側で強制できない。Misskey 側の「隠す」系は
/// 全部サーバーが強制していて穴が無く、両 SNS を洗ってここだけが
/// 「クライアントが落とせる穴」として残った（`docs/server-settings-gap-inventory.md`）。
///
/// ⚠ **壊れても誰も気づかない。**投稿自体は公開なのでエラーにならず、
/// 「本人が隠したはずのタブが出ている」は本人にしか分からない。Sentry にも
/// ユーザー報告にも出ないので、機械で止める。
///
/// ## この検査の経緯
///
/// #992 の棚卸しは「モデルまでは読んでいるが UI 層で 0 ヒット」と判定して
/// #1076 を起票したが、**実際には #732（v1.44）で 4 つとも実装済みだった**。
/// ⚠ **棚卸しの誤判定。**再発防止として、実装があることを検査で固定する
/// （次に同じ棚卸しをしたとき、この検査が「対応済み」の証拠になる）。
///
/// ソースの文字列で見るのは、プロフィール画面がアダプタ・アカウント・
/// プロバイダを揃えないと pump できないため（`bottom_inset_guard_test.dart`
/// と同じ流儀）。
void main() {
  final source = File(
    'lib/src/ui/screen/profile_screen.dart',
  ).readAsStringSync();

  test('show_media == false でメディアタブを出さない', () {
    expect(
      source,
      contains('showMedia != false'),
      reason:
          '本人が非表示にしたメディアタブを出している (#1076)。'
          '⚠ **`!= false` で書くこと** — フィールドが無いサーバー'
          '（未対応バージョン・他ソフト）では null が来るので、'
          '`== true` にすると従来どおり出す fail-open にならない',
    );
  });

  test('show_media_replies == false でメディアタブに返信を含めない', () {
    expect(
      source,
      contains('showMediaReplies == false'),
      reason: 'メディアタブに返信の添付が混ざる (#1076 / #809)',
    );
    // 取得側へ実際に渡していること。判定だけあって使っていない形を防ぐ。
    expect(
      source,
      contains('excludeReplies: _excludeMediaReplies'),
      reason: '判定はあるが取得クエリへ渡していない (#1076)',
    );
  });

  test('show_featured == false で固定投稿を出さない', () {
    expect(
      source,
      contains('showFeatured != false'),
      reason: '本人が非表示にした固定投稿（フィーチャー）を出している (#1076)',
    );
  });

  test('hide_collections == true でフォロー / フォロワーを出さない', () {
    expect(
      source,
      contains('hideCollections != true'),
      reason:
          '本人が隠したフォロー / フォロワーの導線を出している (#1076)。'
          '⚠ **`!= true` で書くこと**（フィールドが無いサーバーでは出す）',
    );
  });

  test('完全な user を取り直したときタブ集合を追従させる', () {
    // 一覧から来た user には show_media が載っていないことがある。あとから
    // 判明してタブ集合が変わるので、TabController を作り直す必要がある（#732）。
    expect(
      source,
      contains('_syncTabController'),
      reason: 'show_media が後から判明したときにタブ集合が追従しない (#1076 / #732)',
    );
  });
}
