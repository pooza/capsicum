import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' hide EmojiPicker;
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../provider/preferences_provider.dart';
import '../../url_helper.dart';

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
  List<CustomEmoji>? _customEmojis;
  bool _loadingCustom = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  final _unicodeSearchController = TextEditingController();
  String _unicodeSearchQuery = '';

  @override
  void initState() {
    super.initState();
    final hasCustom = widget.adapter is CustomEmojiSupport;
    _tabController = TabController(length: hasCustom ? 2 : 1, vsync: this);
    if (hasCustom) {
      _loadCustomEmojis();
    }
  }

  Future<void> _loadCustomEmojis() async {
    setState(() => _loadingCustom = true);
    try {
      final support = widget.adapter as CustomEmojiSupport;
      final emojis = await support.getEmojis();
      if (mounted) {
        setState(() => _customEmojis = emojis);
      }
    } catch (_) {
      if (mounted) setState(() => _customEmojis = []);
    } finally {
      if (mounted) setState(() => _loadingCustom = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _unicodeSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasCustom = widget.adapter is CustomEmojiSupport;
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: [
            if (hasCustom) const Tab(text: 'カスタム'),
            const Tab(text: 'Unicode'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [if (hasCustom) _buildCustomTab(), _buildUnicodeTab()],
          ),
        ),
      ],
    );
  }

  Widget _buildUnicodeTab() {
    final emojiSet = getDefaultEmojiLocale(const Locale('ja'));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _unicodeSearchController,
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
      child: Wrap(
        children: filtered.map(_buildUnicodeEmojiTile).toList(),
      ),
    );
  }

  Widget _buildUnicodeCategories(List<CategoryEmoji> emojiSet) {
    final recentEmojis = ref.watch(recentEmojisProvider)
        .where((e) => !e.startsWith(':'))
        .toList();
    return ListView(
      children: [
        _buildRecentSection(recentEmojis),
        ...emojiSet
          .where((c) => _categoryLabels.containsKey(c.category))
          .map((category) {
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
                children:
                    category.emoji.map(_buildUnicodeEmojiTile).toList(),
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
          child: Text(
            '最近使った',
            style: Theme.of(context).textTheme.labelMedium,
          ),
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

    // Recent custom emojis.
    final recentCustom = ref.watch(recentEmojisProvider)
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
              if (category.key.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Text(
                    category.key,
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
