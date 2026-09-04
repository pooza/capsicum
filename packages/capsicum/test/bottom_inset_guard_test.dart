import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #1037: 「Scaffold の body 下端を誰も面倒を見ていない画面」を機械で止める検査。
///
/// ## なぜ要るか
///
/// `Scaffold` は body に safe-area inset を**自動では入れない**。Android 15 以降は
/// edge-to-edge が強制でオプトアウトできないので、下端に何も置いていない画面は
/// すべて「最後の要素がナビゲーションバーのボタンに潜り込む」形をしている。
///
/// ⚠ **これは 1 画面のバグではない。**ユーザー報告 (#1037) はスレッド画面だったが、
/// 実際には 40 画面以上が同じ形だった。個別に直すと、次に足した画面で同じ報告が
/// もう一度来る。**穴が開いたことをその場で検出する**のがこの検査の役目。
///
/// ## 何を見ているか
///
/// 「`Scaffold` を持ち、スクロールするウィジェットを含む」画面が、
/// [_absorbers] のどれかを持っていること。ウィジェットツリーを組み立てずソースの
/// 文字列で見るのは、これらの画面がアダプタ・アカウント・プロバイダを揃えないと
/// pump できず、40 画面ぶんの足場を用意するコストに見合わないため
/// （`alt_edit_gate_source_test.dart` と同じ流儀）。
///
/// ⚠ **粗い検査であることは承知の上。**「BottomSafeArea があるが body ではなく
/// ボトムシートに掛かっている」ような取り違えは検出できない。それでも
/// **「何も無い」だけは確実に落ちる**ので、無言で穴が開くことはなくなる。
void main() {
  final screenDir = Directory('lib/src/ui/screen');

  /// 下端の inset を吸っていると認めるもの。
  ///
  /// `SimplePostBar` は自前で `MediaQuery.padding.bottom` を足し、
  /// `ChatComposeRow` は自前で `SafeArea` を持つ。どちらもバーが inset を吸うので、
  /// その画面を `BottomSafeArea` で包むと**バーが画面下端まで伸びなくなる**。
  /// だから「包む」以外の吸い方も通す。
  ///
  /// ⚠ ただし **`if (canPost)` のような条件付きのバーは吸ったことにならない。**
  /// 条件が false の側に何も無ければ穴が開く。実際 #1037 の掃き出しで
  /// channel_timeline / chat_thread / chat_room_timeline の 3 画面がこの形だった。
  /// ここは検出できないので、条件付きバーを足すときは else 側を自分で確認する。
  const absorbers = [
    'BottomSafeArea',
    'SafeArea',
    'bottomNavigationBar:',
    'persistentFooterButtons:',
    // 下端に置くバー。これ自体が inset を吸う（上のコメント参照）。
    'SimplePostBar(',
    'ChatComposeRow(',
  ];

  const scrollables = [
    'ListView',
    'CustomScrollView',
    'ScrollablePositionedList',
    'GridView',
    'SingleChildScrollView',
    'ReorderableListView',
  ];

  /// 下端 inset を **別ファイルの共有 View 側で吸っている**画面 (#1039)。
  ///
  /// ⚠ **exempt とは意味が違う。**あちらは「敷き詰めるのが正しい」画面。
  /// こちらは**吸っているが、吸っている場所がこのファイルに無い**画面で、
  /// 検査が文字列でしか見ていないために落ちるもの。
  ///
  /// ⚠ **足すときは「どのファイルの何が吸っているか」まで書くこと。**
  /// 委譲先を書いておかないと、その View から `BottomSafeArea` が消えたときに
  /// ここが嘘になったことに気づけない。
  const delegated = <String, String>{
    'moderation_list_screen.dart':
        'body は UserListView（user_list_screen.dart）で、'
        'そちらが BottomSafeArea を持つ',
    'follow_requests_screen.dart':
        'body は UserListView（user_list_screen.dart）で、'
        'そちらが BottomSafeArea を持つ',
  };

  /// 下端まで敷き詰めるのが正しい画面。**理由を書いてから足すこと。**
  const exempt = <String, String>{
    // 全画面のメディアビューア。画像 / 動画はナビゲーションバーの裏まで
    // 伸ばすのが正しい。操作 UI 側は自前で padding.bottom を足している。
    'media_viewer_screen.dart': '全画面表示が目的。操作 UI は自前で inset を足している',
    // 起動時のスプラッシュ。スクロールしない。
    'splash_screen.dart': 'スクロールしない',
  };

  test('委譲先を書いた画面が実在し、その委譲先が inset を吸っている', () {
    // [delegated] が嘘になっていないことを確かめる (#1039)。委譲先から
    // BottomSafeArea が消えても、委譲元は検査を素通りしてしまうため。
    for (final name in delegated.keys) {
      final file = File('${screenDir.path}/$name');
      expect(file.existsSync(), isTrue, reason: '$name が存在しない');
    }
    final userList = File(
      '${screenDir.path}/user_list_screen.dart',
    ).readAsStringSync();
    expect(
      userList.contains('BottomSafeArea'),
      isTrue,
      reason: 'UserListView が下端 inset を吸わなくなった。委譲元も直すこと',
    );
  });

  test('Scaffold + スクロールする画面は、下端の inset を誰かが吸っている', () {
    final offenders = <String>[];

    for (final entity in screenDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final name = entity.uri.pathSegments.last;
      if (exempt.containsKey(name)) continue;
      if (delegated.containsKey(name)) continue;

      final source = entity.readAsStringSync();
      if (!source.contains('Scaffold(')) continue;
      if (!scrollables.any(source.contains)) continue;
      if (absorbers.any(source.contains)) continue;

      offenders.add(name);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '下端がナビゲーションバーに潜り込む (#1037)。'
          'Scaffold の body を BottomSafeArea で包むか、'
          '下端に置くバー側で inset を吸うこと。'
          '全画面表示が目的なら exempt に**理由を書いて**追加する',
    );
  });

  test('BottomSafeArea は下だけを見る（左右まで広げない）', () {
    // 左右まで広げると横持ち・ノッチ端末で既存レイアウトの横幅が変わる。
    // 影響範囲を報告 (#1037) の形に閉じるため、下だけにしてある。
    final source = File(
      'lib/src/ui/widget/bottom_safe_area.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('SafeArea(top: false, left: false, right: false'),
      reason: '下以外を有効にすると、横持ち・ノッチ端末で既存レイアウトの横幅が変わる',
    );
  });

  test('inset を自前で測らない（キーボードと衝突させない）', () {
    // `SafeArea` の既定は `padding`。キーボードが出ている間はナビゲーション
    // バーがその裏に隠れて `padding.bottom` が 0 になるので、余計な余白が
    // 残らない。ここで `MediaQuery` を自前で読み始めると、`viewPadding` を
    // 掴んで**キーボードの上に inset ぶんの死んだ余白**を出す形にいつでも
    // 転べる。SafeArea への委譲だけに保つことでそれを防ぐ。
    //
    // ⚠ **コメントを落としてから見る。**doc コメントは「viewPadding ではなく
    // padding を見る」「SimplePostBar が MediaQuery.padding.bottom を足して
    // いる」と経緯を説明しているので、素の文字列検索だと自分の説明文で落ちる。
    final source = File('lib/src/ui/widget/bottom_safe_area.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    expect(
      source,
      isNot(contains('MediaQuery')),
      reason: '自前で inset を測らず SafeArea に委譲する。viewPadding を掴むとキーボードの上に無駄な余白が残る',
    );
  });

  test('ドロワーの ListView が下端 inset を落としていない (#1058)', () {
    // ⚠ **上の掃き出しはこの穴を検出しない。**あれは `Scaffold.body` だけを
    // 見るが、ドロワーは `Scaffold.drawer` という別スロットで、body の外側に
    // 居る。#1037 の修正で 43 画面を包んだあともここだけ残り、フッター
    // （サーバー情報と capsicum の版番号）がナビゲーションバーの下に入って
    // いた。最下部までスクロールしても逃がせず、3 ボタンナビはバーが
    // 不透明なので版番号が完全に隠れる。
    //
    // ⚠ **`BottomSafeArea` で包む形ではないので、absorbers では表せない。**
    // ドロワーは上端のヘッダーが背景を全面に伸ばしたまま内側で
    // `SafeArea(bottom: false)` を持つ作りなので、下端も「包む」ではなく
    // 「`padding` で足す」に揃えてある。だからここは専用の検査にしている。
    final source = File(
      'lib/src/ui/screen/home_screen.dart',
    ).readAsStringSync();

    final start = source.indexOf('Widget _buildDrawer(');
    expect(
      start,
      isNonNegative,
      reason: '_buildDrawer が見つからない。名前が変わったならこの検査のアンカーも直す',
    );
    // 次のメソッド定義までを走査対象にする（ファイル末尾まで見ると、
    // 無関係な ListView の padding を巻き込む）。
    final end = source.indexOf('\n  Widget _', start + 1);
    final drawer = end < 0
        ? source.substring(start)
        : source.substring(start, end);

    expect(
      drawer,
      contains('ListView('),
      reason: 'ドロワーの ListView が見つからない。構造が変わったならこの検査も直す',
    );
    expect(
      drawer,
      isNot(contains('padding: EdgeInsets.zero')),
      reason:
          'ドロワーのフッターがナビゲーションバーの下に潜り込む (#1058)。'
          'ListView の padding に下端 inset を足すこと',
    );
    expect(
      drawer,
      contains('MediaQuery.paddingOf'),
      reason:
          '下端 inset を読んでいない (#1058)。'
          '⚠ `viewPadding` ではなく `padding` を使う（キーボード表示時に 0 になる側）',
    );
  });

  test('ホームのタブにも出る共有 View は、View 側で下端 inset を吸っている', () {
    // ⚠ **上の掃き出しはこの穴を検出しない。**あれはファイル単位で
    // 「`Scaffold(` があり absorber の文字列がどこかにあるか」しか見ない。
    // `notification_screen.dart` は単独画面 `NotificationScreen` の
    // `Scaffold.body` を包んでいたので**合格していたが、同じ View を
    // ホームのタブとして出す経路には穴が空いていた**。
    //
    // `home_screen.dart` の `_buildTabContent` は
    // `withBackground(const NotificationView())` を早期 return するので、
    // `SimplePostBar` を持つ Column（＝タイムライン経路で inset を吸う場所）
    // に到達しない。つまり **`Scaffold` を経由しないホストがある**。
    //
    // ⚠ **`ListView` の暗黙吸収を当てにしない。**`BoxScrollView` は `padding`
    // 未指定なら `MediaQuery` の縦 padding を自動で足すが（実測: 未指定の
    // `ListView` は `maxScrollExtent` が inset ぶん大きい）、
    // `ScrollablePositionedList` は `widget.padding` しか見ない。隣の
    // `AnnouncementView` が同じ構造で無事なのは前者に乗っているからで、
    // 誰かが `padding:` を足した瞬間に無言で穴が開く。
    //
    // 2 ホストある View は「画面側で包む」ではなく「View 側で吸う」に
    // 揃える。`ChannelTimelineView` が先行例。
    const views = <String, String>{
      'notification_screen.dart': '_NotificationViewState',
      'channel_timeline_screen.dart': '_ChannelTimelineViewState',
    };

    final offenders = <String>[];
    views.forEach((file, className) {
      final source = File('lib/src/ui/screen/$file').readAsStringSync();
      final start = source.indexOf('class $className');
      expect(
        start,
        isNonNegative,
        reason: '$file に $className が見つからない。名前が変わったならこの検査のアンカーも直す',
      );
      if (!source.substring(start).contains('BottomSafeArea')) {
        offenders.add('$file / $className');
      }
    });

    expect(
      offenders,
      isEmpty,
      reason:
          'ホームのタブ経路で下端がナビゲーションバーに潜り込む。'
          '共有 View は Scaffold を経由しないホストを持つので、'
          '画面側ではなく **View の build で** BottomSafeArea を掛けること',
    );
  });

  test('スレッド画面がジャンプ FAB のぶんを本文側で確保している (#1059)', () {
    // ⚠ **これは #1037 / #1058 とは重なる相手が違う。**あちらはシステムの
    // ナビゲーションバー、こちらは **アプリ自身の FAB**。FAB は
    // `Scaffold.floatingActionButton` で body の**上に浮く**ため、body を
    // `BottomSafeArea` で包んでも避けられない。スクロール範囲に足していないと、
    // 最下部まで送っても最後の投稿がボタンの下に残り、逃がす手段が無い。
    //
    // ⚠ **`BottomSafeArea` があるから大丈夫、と読まないこと。**両方要る。
    // 片方で足りているように見えるのは、投稿がそこまで届いていないときだけ
    // （実際 2026-09-01 の検証で、1 画面に収まるスレッドを見て「合格」と
    // 誤判定しかけた）。
    final source = File(
      'lib/src/ui/screen/post_detail_screen.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('_jumpFabReservedHeight'),
      reason:
          'ジャンプ FAB のぶんの確保が無い (#1059)。'
          'ScrollablePositionedList の padding に FAB の高さを足すこと',
    );
    expect(
      source,
      contains('showJump'),
      reason: 'FAB の出し分け条件が見当たらない。構造が変わったならこの検査も直す',
    );
    // FAB が出ていないときに足すと下端に無駄な余白が残るので、条件付きで
    // あることまで見る。
    //
    // ⚠ **インデントに依存させない。**整形やネストの変化で落ちる検査は、
    // 中身が正しいのに赤くなって信用を失う（#1037 の掃き出しで
    // `offline_retry_action_gate_source_test.dart` が実際にそうなった）。
    expect(
      source,
      matches(RegExp(r'showJump\s*\?\s*const\s+EdgeInsets\.only\(\s*bottom:')),
      reason:
          'padding が `showJump` で出し分けられていない (#1059)。'
          'FAB が無いときに足すと下端に無駄な余白が残る',
    );
  });
}
