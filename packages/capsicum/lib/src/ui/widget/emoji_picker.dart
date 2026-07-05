import 'dart:async';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart'
    hide EmojiPicker;
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../provider/preferences_provider.dart';
import '../../url_helper.dart';
import 'content_parser.dart';

const _categoryLabels = <Category, String>{
  Category.SMILEYS: 'スマイリー',
  Category.ANIMALS: '動物・自然',
  Category.FOODS: '食べ物・飲み物',
  Category.ACTIVITIES: 'アクティビティ',
  Category.TRAVEL: '旅行・場所',
  Category.OBJECTS: 'もの',
  Category.SYMBOLS: '記号',
  Category.FLAGS: '旗',
};

/// ピッカーのタブ種別。表示順は [_EmojiPickerState._tabs] で確定する。
enum _PickerTab { custom, unicode, word }

class EmojiPicker extends ConsumerStatefulWidget {
  final BackendAdapter adapter;
  final String host;
  final ValueChanged<String> onSelected;
  final MulukhiyaService? mulukhiya;
  final String? accessToken;
  final bool forReaction;

  const EmojiPicker({
    super.key,
    required this.adapter,
    required this.host,
    required this.onSelected,
    this.mulukhiya,
    this.accessToken,
    this.forReaction = false,
  });

  @override
  ConsumerState<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends ConsumerState<EmojiPicker>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final List<_PickerTab> _tabs;
  List<CustomEmoji>? _customEmojis;
  bool _loadingCustom = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _searchQuery = '';
  final _unicodeSearchController = TextEditingController();
  final _unicodeSearchFocusNode = FocusNode();
  String _unicodeSearchQuery = '';

  // 劇中ワードタブ (#614)。読み (ひらがな) でモロヘイヤ word/suggest を引く。
  final _wordSearchController = TextEditingController();
  final _wordSearchFocusNode = FocusNode();
  String _wordQuery = '';
  List<WordSuggestion> _wordResults = [];
  bool _wordLoading = false;
  Timer? _wordDebounce;
  int _wordGeneration = 0;

  // 劇中ワード候補を MFM レンダリング（ルビ＝当て字表示）するための共有
  // レンダラ (#691)。投稿表示と同じ ContentRenderer を流用する。
  ContentRenderer? _wordRenderer;

  /// 劇中ワードタブを出す条件。リアクション用ピッカーでは出さず、モロヘイヤが
  /// `features.word_suggest` を立てているサーバーでのみ有効 (#4397 / #614)。
  bool get _hasWordSuggest =>
      !widget.forReaction && (widget.mulukhiya?.wordSuggestEnabled ?? false);

  @override
  void initState() {
    super.initState();
    final hasCustom = widget.adapter is CustomEmojiSupport;
    _tabs = [
      if (hasCustom) _PickerTab.custom,
      _PickerTab.unicode,
      if (_hasWordSuggest) _PickerTab.word,
    ];
    _tabController = TabController(length: _tabs.length, vsync: this)
      ..addListener(_onTabChanged);
    if (hasCustom) {
      _loadCustomEmojis();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusActiveTabSearch();
    });
  }

  Future<void> _loadCustomEmojis() async {
    setState(() => _loadingCustom = true);
    try {
      final support = widget.adapter as CustomEmojiSupport;
      final emojis = await support.getEmojis();
      // getEmojis() は全件返す (警告判定 / プレビュー兼用)。picker UI には
      // visible_in_picker=true のものだけ並べる (#622)。
      final pickerEmojis = emojis.where((e) => e.visibleInPicker).toList();
      if (mounted) {
        setState(() => _customEmojis = pickerEmojis);
      }
    } catch (_) {
      if (mounted) setState(() => _customEmojis = []);
    } finally {
      if (mounted) {
        setState(() => _loadingCustom = false);
        // loading 中は検索欄が build されていないため、完了後に再度試みる。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusActiveTabSearch();
        });
      }
    }
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (mounted) _focusActiveTabSearch();
  }

  void _focusActiveTabSearch() {
    switch (_tabs[_tabController.index]) {
      case _PickerTab.custom:
        // カスタムタブ。loading 中・空のときは検索欄自体が無いので無視。
        if (!_loadingCustom &&
            _customEmojis != null &&
            _customEmojis!.isNotEmpty) {
          _searchFocusNode.requestFocus();
        }
      case _PickerTab.unicode:
        _unicodeSearchFocusNode.requestFocus();
      case _PickerTab.word:
        _wordSearchFocusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _unicodeSearchController.dispose();
    _unicodeSearchFocusNode.dispose();
    _wordDebounce?.cancel();
    _wordSearchController.dispose();
    _wordSearchFocusNode.dispose();
    _wordRenderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: _tabs.map((t) => Tab(text: _tabLabel(t))).toList(),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _tabs.map(_buildTab).toList(),
          ),
        ),
      ],
    );
  }

  String _tabLabel(_PickerTab tab) {
    switch (tab) {
      case _PickerTab.custom:
        return 'カスタム';
      case _PickerTab.unicode:
        return 'Unicode';
      case _PickerTab.word:
        return '劇中ワード';
    }
  }

  Widget _buildTab(_PickerTab tab) {
    switch (tab) {
      case _PickerTab.custom:
        return _buildCustomTab();
      case _PickerTab.unicode:
        return _buildUnicodeTab();
      case _PickerTab.word:
        return _buildWordTab();
    }
  }

  Widget _buildUnicodeTab() {
    final emojiSet = getDefaultEmojiLocale(const Locale('ja'));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _unicodeSearchController,
            focusNode: _unicodeSearchFocusNode,
            decoration: InputDecoration(
              hintText: '絵文字を検索…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _unicodeSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _unicodeSearchController.clear();
                        setState(() => _unicodeSearchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
            onChanged: (value) {
              setState(() => _unicodeSearchQuery = value.toLowerCase());
            },
          ),
        ),
        Expanded(
          child: _unicodeSearchQuery.isNotEmpty
              ? _buildUnicodeSearchResults(emojiSet)
              : _buildUnicodeCategories(emojiSet),
        ),
      ],
    );
  }

  Widget _buildUnicodeSearchResults(List<CategoryEmoji> emojiSet) {
    final filtered = <Emoji>[];
    for (final category in emojiSet) {
      for (final emoji in category.emoji) {
        if (emoji.keywords.any(
          (k) => k.toLowerCase().contains(_unicodeSearchQuery),
        )) {
          filtered.add(emoji);
        }
      }
    }
    if (filtered.isEmpty) {
      return const Center(child: Text('一致する絵文字がありません'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Wrap(children: filtered.map(_buildUnicodeEmojiTile).toList()),
    );
  }

  Widget _buildUnicodeCategories(List<CategoryEmoji> emojiSet) {
    final recentEmojis = ref
        .watch(recentEmojisProvider)
        .where((e) => !e.startsWith(':'))
        .toList();
    return ListView(
      children: [
        _buildRecentSection(recentEmojis),
        ...emojiSet.where((c) => _categoryLabels.containsKey(c.category)).map((
          category,
        ) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Text(
                  _categoryLabels[category.category] ?? '',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  children: category.emoji.map(_buildUnicodeEmojiTile).toList(),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  void _selectEmoji(String emoji) {
    ref.read(recentEmojisProvider.notifier).add(emoji);
    widget.onSelected(emoji);
  }

  Widget _buildRecentSection(List<String> recents) {
    if (recents.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text('最近使った', style: Theme.of(context).textTheme.labelMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            children: recents.map((emoji) {
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _selectEmoji(emoji),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(emoji, style: const TextStyle(fontSize: 24)),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildUnicodeEmojiTile(Emoji emoji) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _selectEmoji(emoji.emoji),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Text(emoji.emoji, style: const TextStyle(fontSize: 24)),
      ),
    );
  }

  void _onWordQueryChanged(String value) {
    final query = value.trim();
    setState(() => _wordQuery = query);
    _wordDebounce?.cancel();
    // クエリが変わった時点で世代を進め、その世代を検索に引き渡す。以前は次の検索が
    // 実際に開始する (debounce 後) まで世代が据え置かれ、debounce ウィンドウ中に
    // 届いた旧クエリの in-flight 応答が `generation == _wordGeneration` ガードを
    // すり抜けて別の読みの候補を表示しえた (#684)。空入力時も同じく世代を進める。
    final generation = ++_wordGeneration;
    if (query.isEmpty) {
      setState(() {
        _wordResults = [];
        _wordLoading = false;
      });
      return;
    }
    setState(() => _wordLoading = true);
    _wordDebounce = Timer(
      const Duration(milliseconds: 300),
      () => _runWordSearch(query, generation),
    );
  }

  Future<void> _runWordSearch(String query, int generation) async {
    final service = widget.mulukhiya;
    if (service == null) return;
    try {
      final results = await service.suggestWords(q: query, limit: 30);
      if (!mounted || generation != _wordGeneration) return;
      setState(() {
        _wordResults = results;
        _wordLoading = false;
      });
    } catch (_) {
      if (!mounted || generation != _wordGeneration) return;
      setState(() {
        _wordResults = [];
        _wordLoading = false;
      });
    }
  }

  /// 劇中ワードタブ。読み (ひらがな) を打って word/suggest を引く (#614)。
  /// `:` `#` `@` と違いひらがなには専用トリガ文字が無いため、本文へのインライン
  /// 発火はせず、このピッカー内の検索ボックス方式とする (設計 doc)。
  Widget _buildWordTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _wordSearchController,
            focusNode: _wordSearchFocusNode,
            decoration: InputDecoration(
              hintText: '読みで検索…（例: せんかれっこうけん）',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _wordQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _wordSearchController.clear();
                        _onWordQueryChanged('');
                      },
                    )
                  : null,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
            onChanged: _onWordQueryChanged,
          ),
        ),
        Expanded(child: _buildWordResults()),
      ],
    );
  }

  Widget _buildWordResults() {
    if (_wordQuery.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'ひらがな読みで劇中ワードを検索できます。\n'
            'IME に変換候補が出ない専門ワードもここから挿入できます。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_wordLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_wordResults.isEmpty) {
      return const Center(child: Text('一致する語がありません'));
    }
    final renderer = _wordContentRenderer(context);
    return ListView.builder(
      itemCount: _wordResults.length,
      itemBuilder: (context, index) {
        final word = _wordResults[index];
        final subtitle = word.category != null
            ? '${word.reading}・${word.category}'
            : word.reading;
        return ListTile(
          dense: true,
          // 候補は MFM レンダリングし、`$[ruby base reading]` の当て字ルビを
          // 投稿表示と同じ見た目で出す (#691)。プレーン文字列はそのまま素の
          // テキストになるだけなのでサーバー出し分けと独立に常時通して安全。
          title: Text.rich(renderer.renderMfm(word.surface)),
          subtitle: Text(subtitle),
          onTap: () => widget.onSelected(word.surface),
        );
      },
    );
  }

  /// 劇中ワード候補用の [ContentRenderer]。custom emoji はピッカーが読み込み
  /// 済みの一覧から解決する。ruby など MFM のみで links / mentions は付かない
  /// 想定 (#691)。
  ContentRenderer _wordContentRenderer(BuildContext context) {
    return _wordRenderer ??= ContentRenderer(
      baseStyle: Theme.of(context).textTheme.titleMedium ?? const TextStyle(),
      resolveEmoji: (shortcode) {
        final list = _customEmojis;
        if (list == null) return null;
        for (final e in list) {
          if (e.shortcode == shortcode) return e.url;
        }
        return null;
      },
    );
  }

  Widget _buildCustomTab() {
    if (_loadingCustom) {
      return const Center(child: CircularProgressIndicator());
    }
    final emojis = _customEmojis;
    if (emojis == null || emojis.isEmpty) {
      return const Center(child: Text('カスタム絵文字がありません'));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            decoration: InputDecoration(
              hintText: '絵文字を検索…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
            onChanged: (value) {
              setState(() => _searchQuery = value.toLowerCase());
            },
          ),
        ),
        Expanded(
          child: _searchQuery.isNotEmpty
              ? _buildCustomSearchResults(emojis)
              : _buildCustomCategories(emojis),
        ),
      ],
    );
  }

  Widget _buildCustomSearchResults(List<CustomEmoji> emojis) {
    final filtered = emojis
        .where(
          (e) =>
              e.shortcode.toLowerCase().contains(_searchQuery) ||
              e.aliases.any((a) => a.toLowerCase().contains(_searchQuery)),
        )
        .toList();
    if (filtered.isEmpty) {
      return const Center(child: Text('一致する絵文字がありません'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Wrap(children: filtered.map(_buildCustomEmojiTile).toList()),
    );
  }

  Widget _buildCustomCategories(List<CustomEmoji> emojis) {
    final palette = widget.forReaction
        ? ref.watch(emojiReactionPaletteProvider(widget.host))
        : ref.watch(emojiPaletteProvider(widget.host));

    // Index custom emojis by shortcode for palette lookup.
    final emojiByCode = <String, CustomEmoji>{};
    for (final e in emojis) {
      emojiByCode[e.shortcode] = e;
    }

    // Group by category.
    final grouped = <String, List<CustomEmoji>>{};
    for (final emoji in emojis) {
      final cat = emoji.category ?? '';
      (grouped[cat] ??= []).add(emoji);
    }

    final hasPalette = widget.adapter is ReactionSupport;

    // Featured custom emojis (Mastodon 4.6 のカテゴリ代表絵文字、#735)。
    // 各カテゴリの代表を先頭のセクションにまとめて素早く到達できるようにする。
    final featured = emojis.where((e) => e.featured).toList();

    // Recent custom emojis.
    final recentCustom = ref
        .watch(recentEmojisProvider)
        .where((e) => e.startsWith(':') && e.endsWith(':'))
        .toList();

    return ListView(
      children: [
        // Recent custom emojis section.
        if (recentCustom.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(
              '最近使った',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              children: recentCustom.map((entry) {
                final shortcode = entry.replaceAll(':', '');
                final custom = emojiByCode[shortcode];
                if (custom != null) return _buildCustomEmojiTile(custom);
                return const SizedBox.shrink();
              }).toList(),
            ),
          ),
        ],
        // Featured section (Mastodon 4.6 カテゴリ代表絵文字、#735)。
        if (featured.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(
              'フィーチャー',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(children: featured.map(_buildCustomEmojiTile).toList()),
          ),
        ],
        // Palette section (imported from Web UI or empty).
        if (hasPalette && palette.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Text('パレット', style: Theme.of(context).textTheme.labelMedium),
                const Spacer(),
                _buildPaletteMenuButton(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              children: palette.map((entry) {
                // Palette entries are ":shortcode:" (custom) or unicode.
                final shortcode = entry.replaceAll(':', '');
                final custom = emojiByCode[shortcode];
                if (custom != null) {
                  return _buildCustomEmojiTile(custom);
                }
                // Unicode emoji or unresolved — render as text.
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _selectEmoji(entry),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(entry, style: const TextStyle(fontSize: 24)),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
        // Import buttons when palette is empty (Misskey only).
        if (hasPalette && palette.isEmpty) ...[
          if (widget.mulukhiya != null && widget.accessToken != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: OutlinedButton.icon(
                onPressed: _syncFromServer,
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('サーバーから絵文字パレットを同期'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: OutlinedButton.icon(
              onPressed: () => _showImportDialog(context),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Web版の絵文字パレットから一括追加'),
            ),
          ),
        ],
        // Category sections.
        ...grouped.entries.map((category) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 分類のない絵文字 (category 空) は見出しなしだと直前の
              // 「最近使った」/「パレット」と地続きに見えるため、明示的に
              // 「分類なし」の見出しを付けて仕切る。
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Text(
                  category.key.isNotEmpty ? category.key : '分類なし',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  children: category.value.map(_buildCustomEmojiTile).toList(),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildPaletteMenuButton() {
    final hasSync = widget.mulukhiya != null && widget.accessToken != null;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      itemBuilder: (_) => [
        if (hasSync)
          const PopupMenuItem(value: 'sync', child: Text('サーバーから同期')),
        const PopupMenuItem(value: 'reimport', child: Text('テキストから追加')),
        const PopupMenuItem(value: 'clear', child: Text('パレットをクリア')),
      ],
      onSelected: (value) {
        switch (value) {
          case 'sync':
            _syncFromServer();
          case 'reimport':
            _showImportDialog(context);
          case 'clear':
            if (widget.forReaction) {
              ref
                  .read(emojiReactionPaletteProvider(widget.host).notifier)
                  .clear();
            } else {
              ref.read(emojiPaletteProvider(widget.host).notifier).clear();
            }
        }
      },
    );
  }

  Future<void> _syncFromServer() async {
    final mulukhiya = widget.mulukhiya;
    final token = widget.accessToken;
    if (mulukhiya == null || token == null) return;

    try {
      final result = await mulukhiya.getEmojiPalettes(accessToken: token);
      if (!mounted) return;
      if (result.palettes.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('サーバーにパレットが設定されていません')));
        return;
      }
      final host = widget.host;
      final mainEmojis = result.mainEmojis;
      final reactionEmojis = result.reactionEmojis;
      await ref
          .read(emojiPaletteProvider(host).notifier)
          .importFromServer(mainEmojis);
      await ref
          .read(emojiReactionPaletteProvider(host).notifier)
          .importFromServer(reactionEmojis);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${mainEmojis.length}件の絵文字を同期しました')),
        );
      }
    } on DioException catch (e) {
      if (!mounted) return;
      final status = e.response?.statusCode;
      final message = status == 404 ? 'この機能はサーバーで利用できません' : 'サーバーとの同期に失敗しました';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _showImportDialog(BuildContext context) {
    final textController = TextEditingController();
    final host = widget.host;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Webからの一括追加'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('1', style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('お使いのブラウザでリアクションデッキをコピーしたいアカウントにログインしてください'),
              const SizedBox(height: 12),
              const Text('2', style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('同じブラウザで絵文字パレットの設定画面（設定 > 絵文字パレット）を開き、コピーしてください'),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => launchUrlSafely(
                  Uri.parse('https://$host/settings/emoji-palette'),
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(
                  'https://$host/settings/emoji-palette',
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.primary,
                    fontSize: 13,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text('3', style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('コピーしたものを下のテキストボックスに貼り付けてください'),
              const SizedBox(height: 8),
              TextField(
                controller: textController,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'ここに貼り付け',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              final text = textController.text.trim();
              if (text.isNotEmpty) {
                ref
                    .read(emojiPaletteProvider(host).notifier)
                    .importFromText(text);
              }
              Navigator.pop(dialogContext);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomEmojiTile(CustomEmoji emoji) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _selectEmoji(':${emoji.shortcode}:'),
      child: Tooltip(
        message: ':${emoji.shortcode}:',
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 32, maxWidth: 96),
            child: Image.network(
              emoji.url,
              height: 32,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image, size: 32),
            ),
          ),
        ),
      ),
    );
  }
}
