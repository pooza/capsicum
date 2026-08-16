import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';
import '../../util/reentrancy_guard.dart';
import '../util/livecure_snackbar.dart';
import '../util/shortcode_warning_controller.dart';
import '../util/visible_timeline.dart';
import 'desktop_menu_model.dart';
import 'insert_picker_sheet.dart';
import 'screen_menu.dart';

class SimplePostBar extends ConsumerStatefulWidget {
  /// Channel ID to post into (Misskey channels).
  final String? channelId;

  /// Channel name for display in compose screen.
  final String? channelName;

  /// Hashtag to prepend to the post content.
  final String? hashtag;

  /// Called after a successful post (for refreshing the caller's timeline).
  final VoidCallback? onPosted;

  const SimplePostBar({
    super.key,
    this.channelId,
    this.channelName,
    this.hashtag,
    this.onPosted,
  });

  @override
  ConsumerState<SimplePostBar> createState() => _SimplePostBarState();
}

class _SimplePostBarState extends ConsumerState<SimplePostBar>
    with WidgetsBindingObserver {
  final _controller = ShortcodeWarningController();
  final _focusNode = FocusNode();
  bool _sending = false;
  bool _paletteOpen = false;

  @override
  void initState() {
    super.initState();
    // ソフトキーボード表示中だけ「しまう」ボタンを出すため、metrics 変化を
    // 受けて rebuild する (#594 / #630)。
    WidgetsBinding.instance.addObserver(this);
    // テキスト編集のたびに未登録 shortcode を再評価する (#609 / compose_screen
    // の _onTextChanged と同等)。IME 変換中は controller 側の guard で警告
    // 装飾が抑えられるので、ここでは値が変わるたび無条件に流す。
    _controller.addListener(_updateShortcodeWarnings);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_updateShortcodeWarnings);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  /// 自サーバー custom_emojis に未登録の shortcode を controller に渡す (#609)。
  /// adapter が MastodonAdapter かつ custom_emojis ロード済みの時だけ作動し、
  /// それ以外 (Misskey ・ ロード前) は空集合で警告を出さない。
  void _updateShortcodeWarnings() {
    final adapter = ref.read(currentAdapterProvider);
    final emojis = ref.read(customEmojisProvider).valueOrNull;
    if (adapter is! MastodonAdapter || emojis == null) {
      _controller.setUnknownShortcodes(const {});
      return;
    }
    final known = {for (final e in emojis) e.shortcode};
    final unknown = <String>{};
    for (final match in shortcodePattern.allMatches(_controller.text)) {
      final code = match.group(1)!;
      if (!known.contains(code)) unknown.add(code);
    }
    _controller.setUnknownShortcodes(unknown);
  }

  /// 送信の再入ガード (#908)。UI 無効化に使う `_sending` は確認設定の読み出しを
  /// await した後にしか立たないため、その窓で二連打が二重投稿になりえた。簡易バーは
  /// TextField の Enter 送信もあるぶん踏みやすい。
  final _submitGuard = ReentrancyGuard();

  Future<void> _submit() => _submitGuard.run(_submitInternal);

  Future<void> _submitInternal() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    if (await ref.read(confirmBeforePostProvider.notifier).readPersisted()) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('確認'),
          content: const Text('投稿しますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('投稿'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final content = widget.hashtag != null
        ? '$text\n\n#${widget.hashtag}'
        : text;

    setState(() => _sending = true);
    try {
      final posted = await adapter.postStatus(
        PostDraft(content: content, channelId: widget.channelId),
      );
      if (mounted) {
        _controller.clear();
        if (widget.channelId == null && posted != null) {
          // #717: 自分の投稿を TL 先頭へ楽観的に挿入する（REST 全再取得に
          // 依存させず、サーバー伝播レースでも必ず即座に出す）。ハッシュタグ
          // タブを見ているときはそちらにも入れる (#887)。
          readVisibleTimelines(ref).insertOwnPost(posted);
        } else {
          ref.invalidate(timelineProvider);
        }
        // #433: hideLivecure ON 中に #実況 を含む投稿 (モロヘイヤ自動付与含む)
        // は TL から除外されるため SnackBar で告知。
        maybeShowHideLivecureSnackBar(context, ref, posted);
        widget.onPosted?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${ref.read(postLabelProvider)}に失敗しました')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openCompose() async {
    final extra = <String, dynamic>{};
    final text = _controller.text;
    if (text.isNotEmpty) {
      extra['initialText'] = text;
    }
    if (widget.channelId != null) {
      extra['channelId'] = widget.channelId;
      extra['channelName'] = widget.channelName;
    }
    final posted = await context.push<bool>(
      '/compose',
      extra: extra.isNotEmpty ? extra : null,
    );
    if (posted == true && mounted) {
      _controller.clear();
    }
  }

  /// カーソル位置（または末尾）に文字列を挿入する。履歴には積まない (劇中ワード
  /// 等の非絵文字を絵文字履歴ストリップに混ぜないため。拡張ピッカーから使う / #614)。
  void _insertText(String entry) {
    final selection = _controller.selection;
    final text = _controller.text;
    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;
    _controller.value = TextEditingValue(
      text: text.replaceRange(start, end, entry),
      selection: TextSelection.collapsed(offset: start + entry.length),
    );
  }

  /// 絵文字を挿入しつつ履歴に積む。recentEmojisProvider の add は LRU で先頭に
  /// 持ち上がるため、再選択でも履歴順序がリフレッシュされる。
  void _insertEmoji(String entry) {
    _insertText(entry);
    ref.read(recentEmojisProvider.notifier).add(entry);
  }

  void _togglePalette() => setState(() => _paletteOpen = !_paletteOpen);

  /// フルピッカー導線 (#614)。絵文字 (カスタム / Unicode) と、モロヘイヤ導入
  /// サーバーでは劇中ワードタブを開く。上の履歴ストリップは高速挿入経路として
  /// 残し、こちらは全機能経路として二段構えにする。
  ///
  /// ツールバーとデスクトップメニュー (#835) の両方から呼ぶため名前付きにして
  /// ある（無名関数だとメニュー項目の値等価が成立せず、再ビルドのたびに
  /// メニューバーが作り直される）。
  Future<void> _openInsertPicker() async {
    // ピッカーは onSelected → Navigator.pop の順で閉じるため、_insertText 内で
    // requestFocus しても直後の pop に奪われる。シートが閉じきる await 後に戻す。
    // 挿入位置のカーソルは _insertText がセット済み (#614)。
    var inserted = false;
    await showInsertPickerSheet(
      context: context,
      ref: ref,
      onSelected: (value) {
        inserted = true;
        _insertText(value);
      },
      closeOnSelect: true,
    );
    // 選択せず閉じた場合はキーボードを再度開かない。
    if (!inserted || !mounted) return;
    // _insertText がセットした挿入直後の collapsed キャレット位置を、再フォーカスで
    // 打ち消される前に退避しておく。
    final caret = _controller.selection.baseOffset;
    _focusNode.requestFocus();
    // desktop では requestFocus による再フォーカス時にテキスト全体が選択状態へ
    // 戻る Flutter 挙動があり、挿入直後のキャレットが選択に化ける (#709)。
    // 再フォーカス確定後の次フレームで collapsed キャレットを再適用して打ち消す。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final len = _controller.text.length;
      final off = (caret >= 0 && caret <= len) ? caret : len;
      _controller.selection = TextSelection.collapsed(offset: off);
    });
  }

  /// 簡易投稿バーがデスクトップメニューバーに出す項目 (#835)。
  ///
  /// 投稿画面のメニューの**サブセット**にあたる。簡易バーはアイコン 3〜5 個まで
  /// 切り詰めた導線なので、そこに無い操作（公開範囲・添付・予約投稿等）は出さない。
  /// 出す条件もツールバー側と同一にする。「キーボードをしまう」はソフトキーボード
  /// が出ているときだけの項目で、メニューバーのあるデスクトップには原理的に
  /// 出ないため除く。
  ///
  /// 送信中フラグ・パレット開閉といった State の可変値に依存するので private の
  /// まま置く（`desktop_menu_model.dart` の「画面メニュー貢献のテストの流儀」
  /// #960）。
  List<MenuEntry> _buildScreenMenuEntries({
    required String postLabel,
    required bool hasRecents,
  }) {
    final busy = _sending;
    return [
      MenuActionEntry(
        label: postLabel,
        icon: Icons.send,
        onSelected: busy ? null : _submit,
      ),
      const MenuGroupSeparator(),
      MenuActionEntry(
        label: '絵文字・劇中ワード…',
        icon: Icons.add_reaction_outlined,
        onSelected: busy ? null : _openInsertPicker,
      ),
      if (hasRecents)
        MenuActionEntry(
          label: '絵文字履歴',
          checked: _paletteOpen,
          onSelected: busy ? null : _togglePalette,
        ),
      const MenuGroupSeparator(),
      MenuActionEntry(
        label: '詳細な$postLabel画面…',
        icon: Icons.open_in_new,
        onSelected: busy ? null : _openCompose,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // customEmojis ロード完了 / アカウント切替で再評価する (#609)。テキスト
    // 編集由来の再評価は controller listener が拾うので、ここはロード状態の
    // 変化のみ拾えば十分。
    ref.listen(customEmojisProvider, (_, _) => _updateShortcodeWarnings());
    final postLabel = ref.watch(postLabelProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final recents = ref.watch(recentEmojisProvider);
    // recentEmojisProvider はサーバー横断で共有されるため、現在サーバーに無い
    // カスタム絵文字は描画段階で除外する（emoji_picker と同じ流儀 / #421）。
    final customEmojis =
        ref.watch(customEmojisProvider).valueOrNull ?? const [];
    final customByCode = {for (final e in customEmojis) e.shortcode: e};
    final visibleRecents = recents.where((entry) {
      if (entry.startsWith(':') && entry.endsWith(':')) {
        final shortcode = entry.substring(1, entry.length - 1);
        final custom = customByCode[shortcode];
        return custom != null && custom.url.isNotEmpty;
      }
      return true;
    }).toList();
    final hasRecents = visibleRecents.isNotEmpty;

    final bar = Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_paletteOpen && hasRecents)
            _buildPalette(visibleRecents, customByCode),
          // 各アクションは IconButton 既定の 48px タップ枠で横幅を食う。小型
          // スマホで最大 5 個並ぶと TextField が画面半分以下に潰れるため、
          // 幅 36px のコンパクト枠に一括で詰める (タップ高さ 40px は確保)。
          IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(36, 40),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    enabled: !_sending,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: '$postLabel...',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // ソフトキーボードが画面に出ているときだけ「しまう」ボタンを
                // 出す (#594)。IME 側に dismiss ボタンが無い環境 (Android ATOK
                // 等) の fallback。Scaffold body 内では MediaQuery.viewInsets
                // が剥がれて 0 になるため、View.of(context) で root view から
                // 拾う。focus 判定だと desktop / iPad + 物理キーボード時に
                // ボタン列が 1 個右にずれて誤投稿が起きていた (#630)。
                if (View.of(context).viewInsets.bottom > 0)
                  IconButton(
                    icon: const Icon(Icons.keyboard_hide, size: 20),
                    tooltip: 'キーボードをしまう',
                    onPressed: () => _focusNode.unfocus(),
                  ),
                // 絵文字履歴ストリップのトグル (#614)。アイコンはフルピッカーの
                // add_reaction_outlined と紛らわしくならないよう、emoji 系でなく
                // 履歴アイコン (Icons.history) を使う。履歴があるときだけ出す。
                if (hasRecents)
                  IconButton(
                    icon: Icon(
                      _paletteOpen ? Icons.expand_less : Icons.history,
                      size: 20,
                    ),
                    tooltip: _paletteOpen ? '履歴を閉じる' : '絵文字履歴',
                    onPressed: _sending ? null : _togglePalette,
                  ),
                IconButton(
                  icon: const Icon(Icons.add_reaction_outlined, size: 20),
                  tooltip: '絵文字・劇中ワード',
                  onPressed: _sending ? null : _openInsertPicker,
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 20),
                  tooltip: '詳細な$postLabel画面',
                  onPressed: _sending ? null : _openCompose,
                ),
                IconButton(
                  icon: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  tooltip: postLabel,
                  onPressed: _sending ? null : _submit,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // 表示中はデスクトップメニューバーにも同じ操作を出す (#835)。簡易バーは
    // ホーム / ハッシュタグ TL / チャンネル TL に置かれるが、宣言が有効なのは
    // 最前面の 1 つだけ（[ScreenMenu] がルートの前後関係で出し分ける）。
    return ScreenMenu(
      label: postLabel,
      entries: _buildScreenMenuEntries(
        postLabel: postLabel,
        hasRecents: hasRecents,
      ),
      child: bar,
    );
  }

  Widget _buildPalette(
    List<String> recents,
    Map<String, CustomEmoji> customByCode,
  ) {
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: recents.length,
        itemBuilder: (context, index) =>
            _buildPaletteItem(recents[index], customByCode),
      ),
    );
  }

  Widget _buildPaletteItem(
    String entry,
    Map<String, CustomEmoji> customByCode,
  ) {
    final isCustom = entry.startsWith(':') && entry.endsWith(':');
    Widget child;
    if (isCustom) {
      final shortcode = entry.substring(1, entry.length - 1);
      final custom = customByCode[shortcode];
      if (custom != null && custom.url.isNotEmpty) {
        child = SizedBox(
          width: 28,
          height: 28,
          child: Image.network(
            custom.url,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) =>
                Text(entry, style: const TextStyle(fontSize: 12)),
          ),
        );
      } else {
        child = Text(entry, style: const TextStyle(fontSize: 12));
      }
    } else {
      child = Text(entry, style: const TextStyle(fontSize: 24));
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _insertEmoji(entry),
      child: Padding(padding: const EdgeInsets.all(6), child: child),
    );
  }
}
