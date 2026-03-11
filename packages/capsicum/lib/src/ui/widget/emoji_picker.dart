import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

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

class EmojiPicker extends StatefulWidget {
  final BackendAdapter adapter;
  final ValueChanged<String> onSelected;

  const EmojiPicker({
    super.key,
    required this.adapter,
    required this.onSelected,
  });

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<CustomEmoji>? _customEmojis;
  bool _loadingCustom = false;

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
      final emojis = await (widget.adapter as CustomEmojiSupport).getEmojis();
      if (mounted) setState(() => _customEmojis = emojis);
    } catch (_) {
      if (mounted) setState(() => _customEmojis = []);
    } finally {
      if (mounted) setState(() => _loadingCustom = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
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

    // Group by category.
    final grouped = <String, List<CustomEmoji>>{};
    for (final emoji in emojis) {
      final cat = emoji.category ?? '';
      (grouped[cat] ??= []).add(emoji);
    }

    return ListView(
      children: grouped.entries.map((category) {
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
                children: category.value.map((emoji) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.onSelected(':${emoji.shortcode}:'),
                    child: Tooltip(
                      message: ':${emoji.shortcode}:',
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight: 32,
                            maxWidth: 96,
                          ),
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
                }).toList(),
              ),
            ),
          ],
        );
      }).toList(),
    );
  }
}
