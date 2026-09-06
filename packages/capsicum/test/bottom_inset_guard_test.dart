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
/// 「`Scaffold` を持ち、スクロールするウィジェットを含む」画面が、下端 inset を
/// 吸う形を持っていること（[_absorbsBottomInset]）。ウィジェットツリーを組み立てず
/// ソースで見るのは、これらの画面がアダプタ・アカウント・プロバイダを揃えないと
/// pump できず、40 画面ぶんの足場を用意するコストに見合わないため
/// （`alt_edit_gate_source_test.dart` と同じ流儀）。
///
/// ⚠ **粗い検査であることは承知の上。**「BottomSafeArea があるが body ではなく
/// ボトムシートに掛かっている」ような取り違えは検出できない。それでも
/// **「何も無い」だけは確実に落ちる**ので、無言で穴が開くことはなくなる。
///
/// ## ⚠⚠ 2026-09-06: ガード自身の穴を 4 つ塞いだ (#1061)
///
/// v1.62 のリリース前レビューで、5 本中 4 本のエージェントがこの検査を指摘した。
/// #1037 → #1058 → #1059 → #1060 と穴が **4 回続けて別の切り口から見つかり、
/// そのたびにガードは緑だった**。塞いだのは以下:
///
/// 1. **サブディレクトリを見ていなかった** — `listSync()` が非再帰で、
///    `screen/settings/` の 8 画面が 1 つも検査されていなかった。再帰にするため
///    には「`padding:` を渡していない `ListView` / `GridView` の暗黙吸収」を
///    absorber に足す必要がある（下の [_absorbsBottomInset] を参照）
/// 2. **absorber の判定が緩かった** — 素の `'SafeArea'` を文字列で見ていたので、
///    **下端を吸わない `SafeArea(bottom: false)` でも合格**していた
/// 3. **`scrollables` に `PageView` / `NestedScrollView` / `TabBarView` が無かった**
/// 4. **共有 View を手書きの表で持っていた** — ホームのタブ経路（`Scaffold` を
///    経由しないホスト）を持つ View が増えても自動では拾えなかった。
///    `home_screen` の参照から**自動で列挙**するように変えた
///
/// ## ⚠ ソースは「構造だけ」にしてから見る
///
/// 文字列で見る検査は、**自分の説明文で誤判定する**。日本語コメントに「SafeArea」と
/// 書いただけで absorber があることになるし、文字列リテラル中の `(` で括弧の対応が
/// 崩れて引数の切り出しが壊れる。構造を見る判定はすべて [_structural] を通す。
void main() {
  final screenDir = Directory('lib/src/ui/screen');

  /// 文字列の存在だけで「下端 inset を吸っている」と認めてよいもの。
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
  ///
  /// ⚠⚠ **素の `'SafeArea'` はここに置かない (#1061)。**下端を吸わない
  /// `SafeArea(bottom: false)` まで合格してしまう。実在例が `home_screen.dart` の
  /// ドロワーヘッダで、**新規画面が `SafeArea(top: true, bottom: false)` を 1 つ
  /// 持つだけで穴が開く**形だった。`SafeArea` は引数まで見て判定する
  /// （[_absorbsBottomInset]）。
  const literalAbsorbers = [
    // 中身は SafeArea(top: false, left: false, right: false) 固定なので、
    // 引数を見るまでもなく下端を吸う。
    'BottomSafeArea',
    'bottomNavigationBar:',
    'persistentFooterButtons:',
    // 下端に置くバー。これ自体が inset を吸う（上のコメント参照）。
    'SimplePostBar(',
    'ChatComposeRow(',
  ];

  /// スクロールする（＝最後の要素が下端に届きうる）ウィジェット。
  ///
  /// ⚠ **`PageView` / `NestedScrollView` / `TabBarView` は #1061 で追加。**
  /// それまで無かったので、これらだけを持つ画面は「スクロールしない画面」と
  /// 見なされて検査を素通りしていた。
  const scrollables = [
    'ListView',
    'CustomScrollView',
    'ScrollablePositionedList',
    'GridView',
    'SingleChildScrollView',
    'ReorderableListView',
    'PageView',
    'NestedScrollView',
    'TabBarView',
  ];

  /// 下端 inset を **別ファイルの共有 View 側で吸っている**画面 (#1039)。
  ///
  /// ⚠ **exempt とは意味が違う。**あちらは「敷き詰めるのが正しい」画面。
  /// こちらは**吸っているが、吸っている場所がこのファイルに無い**画面で、
  /// 検査がソースでしか見ていないために落ちるもの。
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

  /// `screen/` 配下の全 `.dart`（⚠ **サブディレクトリを含む** — #1061）。
  List<File> screenFiles() =>
      screenDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  /// 画面ファイルの識別子。サブディレクトリを含むので、ファイル名だけだと
  /// `settings/` 配下と衝突しうる。`screen/` からの相対パスで持つ。
  String keyOf(File file) =>
      file.path.substring(screenDir.path.length + 1).replaceAll(r'\', '/');

  test('サブディレクトリの画面も検査対象に入っている (#1061)', () {
    // ⚠ **この検査自身が空振りしていないことを確かめる。**`listSync()` が
    // 非再帰に戻ると、`settings/` の 8 画面が黙って検査対象から消える。
    // 「offenders が空 = 緑」なので、対象が 0 件でも緑になってしまう。
    final keys = screenFiles().map(keyOf).toList();
    expect(
      keys.where((k) => k.startsWith('settings/')),
      isNotEmpty,
      reason:
          'settings/ 配下の画面が 1 つも列挙されていない。'
          'listSync が非再帰に戻っていないか確認すること (#1061)',
    );
    expect(keys, contains('home_screen.dart'));
  });

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

  test('exempt に書いた画面が実在する', () {
    for (final name in exempt.keys) {
      expect(
        File('${screenDir.path}/$name').existsSync(),
        isTrue,
        reason:
            '$name が存在しない。画面を消した / 名前を変えたなら exempt からも外す'
            '（残しておくと「ここは免除済み」という嘘の記述になる）',
      );
    }
  });

  test('Scaffold + スクロールする画面は、下端の inset を誰かが吸っている', () {
    final offenders = <String>[];

    for (final entity in screenFiles()) {
      final key = keyOf(entity);
      if (exempt.containsKey(key)) continue;
      if (delegated.containsKey(key)) continue;

      final code = _structural(entity.readAsStringSync());
      if (!code.contains('Scaffold(')) continue;
      if (!scrollables.any((s) => _usesIdentifier(code, s))) continue;
      if (_absorbsBottomInset(code, literalAbsorbers)) continue;

      offenders.add(key);
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
    final source = _structural(
      File('lib/src/ui/widget/bottom_safe_area.dart').readAsStringSync(),
    );

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
    // ⚠ **`BottomSafeArea` で包む形ではないので、absorber では表せない。**
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
    // 「`Scaffold(` があり absorber がどこかにあるか」しか見ない。
    // `notification_screen.dart` は単独画面 `NotificationScreen` の
    // `Scaffold.body` を包んでいたので**合格していたが、同じ View を
    // ホームのタブとして出す経路には穴が空いていた**（#1060）。
    //
    // `home_screen.dart` の `_buildTabContent` は
    // `withBackground(const NotificationView())` を早期 return するので、
    // `SimplePostBar` を持つ Column（＝タイムライン経路で inset を吸う場所）
    // に到達しない。つまり **`Scaffold` を経由しないホストがある**。
    //
    // ⚠ **`ListView` の暗黙吸収を当てにしない。**`BoxScrollView` は `padding`
    // 未指定なら `MediaQuery` の縦 padding を自動で足すが、
    // `ScrollablePositionedList` は `widget.padding` しか見ない。誰かが
    // `padding:` を足した瞬間に無言で穴が開く。2 ホストある View は
    // 「画面側で包む」ではなく「View 側で吸う」に揃える。
    //
    // ⚠⚠ **対象は手書きの表ではなく `home_screen` の参照から自動で拾う
    // (#1061)。**手書きだと、同じ形の View が増えたときに黙って対象外になる
    // ——「ガードが壊れていても緑」の形そのもの。実際 `AnnouncementView` は
    // 表に入っておらず、`ListView` の暗黙吸収に乗っているだけだった。
    final homeCode = _structural(
      File('lib/src/ui/screen/home_screen.dart').readAsStringSync(),
    );

    // `screen/` 配下で定義されている `*View` クラス（Flutter の `ListView` 等は
    // ここに載らないので自然に除外される）。
    final defined = <String, File>{};
    for (final file in screenFiles()) {
      final code = _structural(file.readAsStringSync());
      for (final m in RegExp(
        r'(?<![A-Za-z0-9_])class\s+([A-Z][A-Za-z0-9_]*View)(?![A-Za-z0-9_])',
      ).allMatches(code)) {
        defined[m.group(1)!] = file;
      }
    }

    final shared =
        RegExp(r'(?<![A-Za-z0-9_])([A-Z][A-Za-z0-9_]*View)\s*\(')
            .allMatches(homeCode)
            .map((m) => m.group(1)!)
            .where(defined.containsKey)
            .toSet()
            .toList()
          ..sort();

    // ⚠ **自動列挙が空振りしていないことを先に固定する。**正規表現が壊れると
    // 対象 0 件でも「offenders は空」で緑になる。既知の 3 件は必ず入る。
    expect(
      shared,
      containsAll(<String>[
        'AnnouncementView',
        'ChannelTimelineView',
        'NotificationView',
      ]),
      reason:
          'home_screen が組み立てる共有 View の自動列挙が壊れている (#1061)。'
          'ここが空振りすると、下の掃き出しは何も検査していないのに緑になる',
    );

    final offenders = <String>[];
    for (final name in shared) {
      final file = defined[name]!;
      final code = _structural(file.readAsStringSync());
      // ウィジェットクラス本体と、その State クラス本体のどちらかで吸っていればよい
      // （`ConsumerStatefulWidget` は build が State 側にある）。
      final bodies = [
        _topLevelClassBody(code, name),
        _topLevelClassBody(code, '_${name}State'),
      ].whereType<String>();
      if (bodies.any((b) => b.contains('BottomSafeArea'))) continue;
      offenders.add('${keyOf(file)} / $name');
    }

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

  // ---------------------------------------------------------------------
  // ⚠ 判定ロジック自身の検査 (#1061)。
  //
  // 上の掃き出しは「offenders が空なら緑」なので、**判定が常に true を返す
  // ように壊れても緑になる**。#1061 が塞いだ穴（緩い SafeArea・暗黙吸収）は
  // どちらも判定側の話なので、判定にサンプルを食わせて歯があることを固定する。
  // ---------------------------------------------------------------------
  group('判定ロジック自身 (#1061)', () {
    const absorbers = [
      'BottomSafeArea',
      'bottomNavigationBar:',
      'persistentFooterButtons:',
      'SimplePostBar(',
      'ChatComposeRow(',
    ];

    bool absorbs(String source) =>
        _absorbsBottomInset(_structural(source), absorbers);

    test('SafeArea(bottom: false) は吸ったことにならない', () {
      expect(absorbs('SafeArea(top: true, bottom: false, child: x)'), isFalse);
      expect(absorbs('SafeArea(bottom: false, child: x)'), isFalse);
    });

    test('素の SafeArea / bottom: true は吸う', () {
      expect(absorbs('SafeArea(child: x)'), isTrue);
      expect(absorbs('SafeArea(top: false, bottom: true, child: x)'), isTrue);
    });

    test('padding 未指定の ListView / GridView は暗黙に吸う', () {
      // BoxScrollView は padding 未指定なら MediaQuery の縦 padding を自動で
      // 足す。settings/ 配下の 8 画面はこれに乗っている。
      expect(absorbs('ListView(children: [a, b])'), isTrue);
      expect(absorbs('GridView.count(crossAxisCount: 2)'), isTrue);
    });

    test('padding を渡した ListView は暗黙吸収に乗らない', () {
      expect(
        absorbs('ListView(padding: EdgeInsets.zero, children: [a])'),
        isFalse,
      );
      expect(
        absorbs('ListView.builder(padding: p, itemBuilder: (c, i) => x)'),
        isFalse,
      );
    });

    test('子ウィジェットの padding を ListView のものと取り違えない', () {
      // ⚠ 引数列は **depth 0 のカンマ**で切る。素朴に「引数列に padding: が
      // あるか」で見ると、children の中の Padding を拾って
      // 「暗黙吸収に乗っていない」と誤判定する。
      expect(
        absorbs('ListView(children: [Padding(padding: p, child: x)])'),
        isTrue,
      );
    });

    test('コメントや文字列の中の SafeArea を数えない', () {
      expect(absorbs('// SafeArea で包む\nListView(padding: p)'), isFalse);
      expect(absorbs("Text('SafeArea')\nListView(padding: p)"), isFalse);
    });

    test('BottomSafeArea は SafeArea の判定に巻き込まれず、単体で吸う', () {
      expect(absorbs('BottomSafeArea(child: x)'), isTrue);
    });

    test('何も無ければ吸わない', () {
      expect(absorbs('Scaffold(body: ListView(padding: p))'), isFalse);
    });
  });

  group('ソースの構造化 (#1061)', () {
    test('補間の中の文字列でリテラルが途切れない', () {
      // announcement_screen に実在する形。素朴なスキャナだと
      // `'${acct.startsWith('` で文字列が終わったことになり、残りの
      // `@') ...` がコードとして残って括弧の対応が崩れる。
      const source =
          "final s = '\$name (\${acct.startsWith('@') ? acct : '@\$acct'})';\n"
          'ListView(children: [a])';
      expect(_absorbsBottomInset(_structural(source), const []), isTrue);
    });

    test('ブロックコメントと raw 文字列を落とす', () {
      expect(_structural('/* SafeArea */ a'), isNot(contains('SafeArea')));
      expect(_structural(r"a = r'SafeArea\'; b"), isNot(contains('SafeArea')));
    });
  });
}

// -------------------------------------------------------------------------
// 判定の実装 (#1061)
// -------------------------------------------------------------------------

final _safeAreaCall = RegExp(r'(?<![A-Za-z0-9_])SafeArea\s*\(');

/// `BoxScrollView` のサブクラス。**`padding` 未指定なら `MediaQuery` の縦
/// padding を自動で足す**（`BoxScrollView.buildSlivers`）。
///
/// 実測 (#1061): `padding` 未指定の `ListView` は `maxScrollExtent` が 1463、
/// `padding: EdgeInsets.zero` だと 1400。差の 63 は与えた inset そのもの。
///
/// ⚠ **`ScrollablePositionedList` はこれに乗らない**（`widget.padding` しか
/// 見ない）ので、ここには入れない。
final _boxScrollViewCall = RegExp(
  r'(?<![A-Za-z0-9_])(?:ListView|GridView)(?:\.[A-Za-z0-9_]+)?\s*\(',
);

/// [code]（[_structural] を通したソース）が下端 inset を吸っているか。
bool _absorbsBottomInset(String code, List<String> literalAbsorbers) {
  if (literalAbsorbers.any(code.contains)) return true;

  // `SafeArea` は引数まで見る。`bottom: false` は下端を吸わない (#1061)。
  for (final args in _callArguments(code, _safeAreaCall)) {
    if (_namedArgument(args, 'bottom')?.trim() != 'false') return true;
  }

  // `padding` を渡していない `ListView` / `GridView` の暗黙吸収 (#1061)。
  for (final args in _callArguments(code, _boxScrollViewCall)) {
    if (_namedArgument(args, 'padding') == null) return true;
  }

  return false;
}

/// [name] という識別子が [code] に現れるか。
///
/// ⚠ **部分一致にしない。**`PageView` は `PageViewScreen` に、`ListView` は
/// `ReorderableListView` に含まれる。素の `contains` だと別物を拾う。
bool _usesIdentifier(String code, String name) => RegExp(
  '(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])',
).hasMatch(code);

/// [head] が当たった呼び出しごとに、括弧の対応を取って引数列を返す。
List<String> _callArguments(String code, RegExp head) {
  final result = <String>[];
  for (final m in head.allMatches(code)) {
    final open = code.indexOf('(', m.start);
    if (open < 0) continue;
    var depth = 0;
    var i = open;
    for (; i < code.length; i++) {
      final c = code[i];
      if (c == '(' || c == '[' || c == '{') {
        depth++;
      } else if (c == ')' || c == ']' || c == '}') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (i >= code.length) continue; // 対応が取れない（構造化に失敗している）
    result.add(code.substring(open + 1, i));
  }
  return result;
}

/// 引数列 [args] のうち **depth 0 の** `name:` の値。無ければ null。
///
/// ⚠ **depth 0 で切るのが肝。**素朴に `args.contains('padding:')` で見ると、
/// `ListView(children: [Padding(padding: ...)])` の子を拾って誤判定する。
String? _namedArgument(String args, String name) {
  var depth = 0;
  var start = 0;
  final segments = <String>[];
  for (var i = 0; i < args.length; i++) {
    final c = args[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == ',' && depth == 0) {
      segments.add(args.substring(start, i));
      start = i + 1;
    }
  }
  segments.add(args.substring(start));

  final prefix = '$name:';
  for (final segment in segments) {
    final trimmed = segment.trimLeft();
    if (trimmed.startsWith(prefix)) {
      return trimmed.substring(prefix.length);
    }
  }
  return null;
}

/// [className] のトップレベル宣言から、次のトップレベル `class` までを返す。
String? _topLevelClassBody(String code, String className) {
  final start = RegExp(
    '(?<![A-Za-z0-9_])class\\s+${RegExp.escape(className)}(?![A-Za-z0-9_])',
  ).firstMatch(code)?.start;
  if (start == null) return null;
  final next = RegExp(
    r'\nclass\s',
  ).firstMatch(code.substring(start + 1))?.start;
  return next == null
      ? code.substring(start)
      : code.substring(start, start + 1 + next);
}

/// コメントと文字列リテラルを落とした「構造だけ」のソース。
///
/// ⚠ **文字列で見る検査は自分の説明文で誤判定する。**日本語コメントに
/// 「SafeArea」と書いただけで absorber があることになり、文字列中の `(` で
/// 括弧の対応が崩れる。
///
/// ⚠ **補間 `${...}` の中は Dart のコードなので、波括弧の対応を取って飛ばす。**
/// ここを素朴に「次の同じ引用符まで」で切ると、`'${a.b('c')}'` のような実在の
/// 形で文字列が途中で終わったことになり、残りがコードとして混ざる。
String _structural(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      i = end < 0 ? source.length : end + 2;
      continue;
    }
    final delimiter = _stringDelimiterAt(source, i);
    if (delimiter != null) {
      i = _skipString(source, i, delimiter);
      continue;
    }
    out.write(source[i]);
    i++;
  }
  return out.toString();
}

/// [i] から文字列リテラルが始まるなら、その開始デリミタ。
String? _stringDelimiterAt(String source, int i) {
  var j = i;
  if (source[j] == 'r' && j + 1 < source.length) j++; // raw 文字列
  if (source.startsWith("'''", j)) return "'''";
  if (source.startsWith('"""', j)) return '"""';
  if (j < source.length && (source[j] == "'" || source[j] == '"')) {
    return source[j];
  }
  return null;
}

/// [i] から始まる文字列リテラルの直後の位置を返す。
int _skipString(String source, int i, String delimiter) {
  var j = i;
  final raw = source[j] == 'r';
  if (raw) j++;
  j += delimiter.length;

  while (j < source.length) {
    if (!raw && source[j] == r'\') {
      j += 2;
      continue;
    }
    if (!raw && source.startsWith(r'${', j)) {
      j++; // '$' を消費し、'{' から対応を取る
      var depth = 0;
      while (j < source.length) {
        final c = source[j];
        if (c == '{') {
          depth++;
        } else if (c == '}') {
          depth--;
          if (depth == 0) {
            j++;
            break;
          }
        } else {
          final nested = _stringDelimiterAt(source, j);
          if (nested != null) {
            j = _skipString(source, j, nested);
            continue;
          }
        }
        j++;
      }
      continue;
    }
    if (source.startsWith(delimiter, j)) return j + delimiter.length;
    j++;
  }
  return source.length;
}
