import 'package:flutter/material.dart';

/// カスタム絵文字の URL → アスペクト比（幅 ÷ 高さ）を覚えるプロセス内キャッシュ
/// (#1032)。
///
/// **なぜ要るか。**本文中のカスタム絵文字は `height` だけを指定して描いている
/// （幅に固定 cap を置かない方針 = #858）。`RenderImage._sizeForConstraints` は
/// デコードが済むまで `constraints.smallest` を返すので、**幅が未指定のあいだ
/// 幅は 0** になる。デコードが済んだ瞬間に実寸へ跳ね、`Text.rich` の折り返し位置
/// ＝行数が変わり、**投稿タイルの高さが変わる**。
///
/// タイムラインの `RenderSliverList` はビューポート外の高さを dead reckoning で
/// 持っているため、上へ戻って破棄済みタイルを作り直したときに実測が想定と食い違うと
/// `SliverGeometry.scrollOffsetCorrection` が出る。補正は `pixels` を動かすので、
/// フリングの慣性が走っている最中だと**目に見える跳ね**になる（報告 = #1032）。
///
/// **なぜ寸法を先に知れないか。**Mastodon の `/api/v1/custom_emojis` も Misskey の
/// `/api/emojis` も**寸法を返さない**（shortcode / url / category 等のみ）。
/// サーバーから貰えない以上、一度デコードして自分で覚えるしかない。
///
/// ⚠ **`ImageCache` の代わりではない。**あちらは画素を持つので既定 1000 枚 /
/// 100 MiB で回転し、実況中に下へ送ると**一度見た絵文字が落ちる**。こちらが持つのは
/// 1 URL あたり `double` 1 個だけなので、桁違いに多く覚えていられる。画素が落ちても
/// **寸法だけは残る**ようにするのがこのクラスの役割で、戻ってきたときの再デコードで
/// 幅 0 のフレームを踏まなくなる。
class EmojiAspectRatioCache {
  EmojiAspectRatioCache({int maxSize = defaultMaxSize}) : _maxSize = maxSize;

  /// 覚えておく URL の上限。
  ///
  /// 1 件あたり URL 文字列 + `double` なので、ダイスキー規模（数千個）の絵文字を
  /// 全部覚えても数百 KB に収まる。上限は暴走時の歯止めであって、通常運転で
  /// 押し出しに当たることは想定していない。
  static const defaultMaxSize = 8192;

  /// アプリ全体で 1 つ。
  static final EmojiAspectRatioCache instance = EmojiAspectRatioCache();

  final int _maxSize;

  /// Dart の Map リテラルは `LinkedHashMap` で挿入順を保つため、`keys.first` が
  /// 最古になる。
  ///
  /// ⚠ **FIFO であって LRU ではない。**参照しても位置は動かさない
  /// (`BoundedKeySet` と同じ理由 = 実装を単純に保つ)。上限に当たらない前提の
  /// 歯止めなので、追い出し順の賢さより挙動の読みやすさを採る。
  final Map<String, double> _ratios = {};

  /// [url] の既知のアスペクト比。未知なら null。
  double? operator [](String url) => _ratios[url];

  /// デコードで判明したアスペクト比を覚える。
  ///
  /// 0 / 負 / NaN / Infinity は捨てる。これらを通すと `size * ratio` が
  /// レイアウトを壊す（`BoxConstraints` の assert で落ちる）。
  ///
  /// ⚠ **既知の URL でも、比が違えば上書きする** (#1038)。初版は「同じ絵文字
  /// なら比は変わらない」として既知の URL を素通りしていたが、**サーバー管理者は
  /// 同じショートコードのまま画像を差し替える**（`/emoji/<shortcode>.webp` の
  /// ような安定 URL を使う経路が実在する）。素通りさせると、`ImageCache` が
  /// 画素を追い出して読み直したあとも古い比で幅を渡し続け、**再起動するまで
  /// レターボックス / 潰れた幅のまま**になる。
  ///
  /// 上書きしても **FIFO の位置は動かない**。`LinkedHashMap` は既存キーへの
  /// 代入で挿入順を変えないため、[_maxSize] の追い出し順は「最初に覚えた順」の
  /// ままになる（参照でも再記録でも位置を動かさない = [_ratios] の doc）。
  void record(String url, double ratio) {
    if (!ratio.isFinite || ratio <= 0) return;
    if (_ratios[url] == ratio) return;
    _ratios[url] = ratio;
    while (_ratios.length > _maxSize) {
      _ratios.remove(_ratios.keys.first);
    }
  }

  @visibleForTesting
  int get length => _ratios.length;

  @visibleForTesting
  void clear() => _ratios.clear();
}

/// 本文中に 1 個ぶんのカスタム絵文字を描く `WidgetSpan` の中身 (#1032)。
///
/// `content_parser`（投稿本文の MFM / HTML）と `emoji_text`（表示名・カスタム絵文字
/// 入りの短いテキスト）の**両方から使う**。以前は同じ形の
/// `ConstrainedBox` + `Image.network` が 2 箇所に複写されており、#858 のときも
/// 「2 箇所で挙動を揃えている」とコメントで縛っていた。挙動を揃えたいなら
/// widget を 1 つにするのが素直なので、ここへ寄せた。
class InlineCustomEmoji extends StatefulWidget {
  const InlineCustomEmoji({
    super.key,
    required this.url,
    required this.shortcode,
    required this.size,
    this.maxWidthFactor,
    this.fallback,
    this.cache,
    this.imageProvider,
  });

  /// 絵文字画像の URL。
  final String url;

  /// 画像を出せなかったときに生テキストで見せるショートコード（`:` は含まない）。
  final String shortcode;

  /// 幅の上限を「高さの N 倍」で課す。null なら上限なし。
  ///
  /// ⚠ **本文（`content_parser` / `emoji_text`）では必ず null にする** — 固定 cap を
  /// 置くと 3:1 を超える横長絵文字が `BoxFit.contain` で細い帯に潰れる (#858)。
  /// 一方**リアクションチップは 3 倍 cap を意図的に維持する** (#924)。撤廃すると
  /// チップが横に伸びて行が崩れるため、方針が本文と異なる。
  final double? maxWidthFactor;

  /// 画像を出せなかったときの差し替え。null なら `:shortcode:` を出す。
  ///
  /// リアクションチップは `:shortcode:` ではなく生のリアクションキーを、
  /// チップに収まる倍率（[AppConstants.emojiFallbackTextScale]）で出すため、
  /// 呼び出し側から渡せるようにしてある。
  final Widget? fallback;

  /// 絵文字の表示高さ。`emojiSizeProvider` の値に、MFM の `$[x2]` 等による
  /// 倍率を掛けたもの (#844)。
  final double size;

  /// テスト用の差し替え口。既定はプロセス共有の
  /// [EmojiAspectRatioCache.instance]。
  final EmojiAspectRatioCache? cache;

  /// テスト用の差し替え口。既定は `NetworkImage(url)`。
  ///
  /// 実画像のデコードを伴う挙動（比の測り直し = #1038）を widget テストから
  /// 駆動するために開けてある。本番経路では渡さない。
  @visibleForTesting
  final ImageProvider? imageProvider;

  @override
  State<InlineCustomEmoji> createState() => _InlineCustomEmojiState();
}

class _InlineCustomEmojiState extends State<InlineCustomEmoji> {
  late ImageProvider _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _ratio;

  /// この URL について、この mount でもう実寸を測ったか (#1038)。
  ///
  /// 測るのは **1 mount につき 1 回**。取れたら [_unsubscribe] して手放すので、
  /// これが無いと `didChangeDependencies` が呼ばれるたび（テーマ変更・
  /// `MediaQuery` の更新等）に resolve をやり直すことになる。
  bool _measured = false;

  EmojiAspectRatioCache get _cache =>
      widget.cache ?? EmojiAspectRatioCache.instance;

  @override
  void initState() {
    super.initState();
    _provider = widget.imageProvider ?? NetworkImage(widget.url);
    _ratio = _cache[widget.url];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeIfNeeded();
  }

  @override
  void didUpdateWidget(InlineCustomEmoji oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url == widget.url) return;
    _provider = widget.imageProvider ?? NetworkImage(widget.url);
    _ratio = _cache[widget.url];
    _measured = false;
    _unsubscribe();
    _subscribeIfNeeded();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  /// 実寸を 1 回測るために画像ストリームを覗く。
  ///
  /// ⚠ **取れたら即座に手放す。**listener が付いているあいだ `ImageCache` は
  /// その画像を live 扱いにして追い出さないので、購読しっぱなしにすると
  /// キャッシュの回転を止めてしまう。欲しいのは寸法 1 回だけなので、
  /// [_handleImage] の中で [_unsubscribe] する。
  ///
  /// ⚠ **比が既知でも測る** (#1038)。初版は既知なら購読しなかったが、それだと
  /// **新しい寸法を観測する経路自体が閉じる**ため、同じ URL で画像が差し替わって
  /// も古い比を使い続けた。mount のたびに 1 回だけ測り直す形にして、
  /// 「スクロールで捨てられ、戻って作り直される」たびに追随できるようにする。
  ///
  /// ⚠ **これは購読を増やしていない。**画面に出ている `Image` widget 自身が
  /// mount のあいだ同じ completer を購読しているので、`ImageCache` の live 判定は
  /// こちらの有無で変わらない。逆に言えば、**表示中の絵文字はそもそも読み直され
  /// ない**（差し替えに気付けるのは捨てられて作り直された後）。
  void _subscribeIfNeeded() {
    if (_measured || !mounted) return;
    final stream = _provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _unsubscribe();
    final listener = ImageStreamListener(_handleImage, onError: _handleError);
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _unsubscribe() {
    final stream = _stream;
    final listener = _listener;
    _stream = null;
    _listener = null;
    if (stream == null || listener == null) return;
    stream.removeListener(listener);
  }

  void _handleImage(ImageInfo info, bool synchronousCall) {
    final width = info.image.width;
    final height = info.image.height;
    // onImage は受け取った ui.Image の dispose 責任を listener に渡す
    // (`ImageListener` の doc)。ここが要るのは寸法だけなので、読んだら手放す。
    // 画面に出しているのは `Image` widget が自前で購読しているぶんで、こちらの
    // 解放とは別勘定。
    info.dispose();
    // 寸法 0 の画像は比が出せない。壊れた WebP 等で 0 が返る余地があるので、
    // record 側の防御に頼らずここでも弾く（setState を無駄に呼ばない）。
    if (width <= 0 || height <= 0) return;
    final ratio = width / height;
    _cache.record(widget.url, ratio);
    // 寸法が取れた時点で用は済んだ。listener を残すと ImageCache を pin する。
    _measured = true;
    _unsubscribe();
    if (!mounted || _ratio == ratio) return;
    setState(() => _ratio = ratio);
  }

  /// 読み込み失敗は `Image` の `errorBuilder` が拾う。ここは**握り潰す係**で、
  /// onError を渡さないと listener が付いているぶんの例外が未処理として
  /// `FlutterError` に上がってしまう。
  void _handleError(Object error, StackTrace? stackTrace) => _unsubscribe();

  @override
  Widget build(BuildContext context) {
    final ratio = _ratio;
    final maxWidthFactor = widget.maxWidthFactor;
    return ConstrainedBox(
      // 既定では幅に固定の cap を置かない (#858)。`WidgetSpan` の子には
      // `RenderParagraph` が `BoxConstraints(maxWidth: 段落の利用可能幅)` を渡す
      // ため、幅の頭打ちはそちらが担う。cap を課すのは [maxWidthFactor] を
      // 渡された場合（＝リアクションチップ・#924）だけ。
      constraints: BoxConstraints(
        maxHeight: widget.size,
        maxWidth: maxWidthFactor == null
            ? double.infinity
            : widget.size * maxWidthFactor,
      ),
      child: Image(
        image: _provider,
        height: widget.size,
        // デコード前に幅を予約する (#1032)。ここが null だと
        // `_sizeForConstraints` が `constraints.smallest` を返して**幅 0**
        // になり、デコード後に折り返しが変わって投稿の高さが動く。
        //
        // ⚠ **これは幅の cap ではない。**既知の比なら `size * ratio` は
        // デコード後に `constrainSizeAndAttemptToPreserveAspectRatio` が出す値と
        // 一致し、利用可能幅を超えるぶんは従来どおり `enforce` で頭打ちになる
        // （#858 の「横長絵文字を潰さない」は維持される）。
        //
        // 未知のとき正方形（比 1）で置くのは、初見の絵文字は原理的に寸法が
        // 分からないため。0 を置くより実寸に近く、大半を占める正方形の絵文字では
        // ズレが 0 になる。
        width: widget.size * (ratio ?? 1.0),
        fit: BoxFit.contain,
        // ⚠ `errorBuilder` の戻り値には width / height が掛からない
        // (`_ImageState.build` が RawImage ごと差し替える)。フォールバックの
        // 文字サイズは従来どおり据え置き。
        errorBuilder: (_, _, _) =>
            widget.fallback ??
            Text(':${widget.shortcode}:', style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}
