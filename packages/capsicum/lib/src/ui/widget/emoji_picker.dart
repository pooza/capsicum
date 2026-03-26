import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';

const _unicodeEmojiCategories = <String, List<String>>{
  'よく使う': [
    '\u{1F44D}',
    '\u{2764}\u{FE0F}',
    '\u{1F602}',
    '\u{1F60A}',
    '\u{1F389}',
    '\u{1F44F}',
    '\u{1F914}',
    '\u{1F62D}',
    '\u{1F631}',
    '\u{1F525}',
    '\u{2728}',
    '\u{1F64F}',
    '\u{1F60D}',
    '\u{1F917}',
    '\u{1F4AA}',
    '\u{1F44C}',
    '\u{1F4AF}',
    '\u{1F3B6}',
    '\u{2705}',
    '\u{274C}',
  ],
  'スマイリー': [
    '\u{1F600}',
    '\u{1F603}',
    '\u{1F604}',
    '\u{1F601}',
    '\u{1F606}',
    '\u{1F605}',
    '\u{1F923}',
    '\u{1F602}',
    '\u{1F642}',
    '\u{1F643}',
    '\u{1F609}',
    '\u{1F60A}',
    '\u{1F607}',
    '\u{1F970}',
    '\u{1F60D}',
    '\u{1F929}',
    '\u{1F618}',
    '\u{1F617}',
    '\u{1F61A}',
    '\u{1F619}',
    '\u{1F60B}',
    '\u{1F61B}',
    '\u{1F61C}',
    '\u{1F92A}',
    '\u{1F61D}',
    '\u{1F911}',
    '\u{1F917}',
    '\u{1F92D}',
    '\u{1F92B}',
    '\u{1F914}',
    '\u{1F910}',
    '\u{1F928}',
    '\u{1F610}',
    '\u{1F611}',
    '\u{1F636}',
    '\u{1F60F}',
    '\u{1F612}',
    '\u{1F644}',
    '\u{1F62C}',
    '\u{1F925}',
  ],
  'ジェスチャー': [
    '\u{1F44D}',
    '\u{1F44E}',
    '\u{1F44F}',
    '\u{1F64C}',
    '\u{1F450}',
    '\u{1F91D}',
    '\u{1F64F}',
    '\u{270D}\u{FE0F}',
    '\u{1F485}',
    '\u{1F4AA}',
    '\u{1F44A}',
    '\u{270A}',
    '\u{1F91B}',
    '\u{1F91C}',
    '\u{1F44C}',
    '\u{1F90F}',
    '\u{270C}\u{FE0F}',
    '\u{1F91E}',
    '\u{1F91F}',
    '\u{1F918}',
  ],
  'ハート': [
    '\u{2764}\u{FE0F}',
    '\u{1F9E1}',
    '\u{1F49B}',
    '\u{1F49A}',
    '\u{1F499}',
    '\u{1F49C}',
    '\u{1F5A4}',
    '\u{1FA76}',
    '\u{1F90D}',
    '\u{1F49D}',
    '\u{1F49E}',
    '\u{1F493}',
    '\u{1F497}',
    '\u{1F496}',
    '\u{1F498}',
    '\u{1F49F}',
    '\u{1F48C}',
  ],
};

class EmojiPicker extends ConsumerStatefulWidget {
  final BackendAdapter adapter;
  final String host;
  final ValueChanged<String> onSelected;

  const EmojiPicker({
    super.key,
    required this.adapter,
    required this.host,
    required this.onSelected,
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
    return ListView(
      children: _unicodeEmojiCategories.entries.map((category) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                children: category.value.map((emoji) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.onSelected(emoji),
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
      }).toList(),
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
    final palette = ref.watch(emojiPaletteProvider(widget.host));

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

    return ListView(
      children: [
        // Palette section (imported from Web UI or empty).
        if (palette.isNotEmpty) ...[
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
                  onTap: () => widget.onSelected(entry),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(entry, style: const TextStyle(fontSize: 24)),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
        // Import button when palette is empty.
        if (palette.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: OutlinedButton.icon(
              onPressed: () => _showImportDialog(context),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Web版の絵文字パレットから一括追加'),
            ),
          ),
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
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'reimport', child: Text('再インポート')),
        const PopupMenuItem(value: 'clear', child: Text('パレットをクリア')),
      ],
      onSelected: (value) {
        switch (value) {
          case 'reimport':
            _showImportDialog(context);
          case 'clear':
            ref.read(emojiPaletteProvider(widget.host).notifier).clear();
        }
      },
    );
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
              const Text('同じブラウザで以下のURLにアクセスして絵文字パレットをコピーしてください'),
              const SizedBox(height: 4),
              SelectableText(
                'https://$host/settings/emoji-palette',
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.primary,
                  fontSize: 13,
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
      onTap: () => widget.onSelected(':${emoji.shortcode}:'),
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
