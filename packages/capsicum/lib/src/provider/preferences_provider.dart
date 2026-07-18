import 'dart:async';
import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/shared_preferences_cache.dart';
import 'account_manager_provider.dart';
import 'channel_provider.dart';
import 'list_provider.dart';

/// User preference keys.
const _fontScaleKey = 'font_scale';
const _themeColorPrefix = 'theme_color_';
const _tabOrderPrefix = 'tab_order_';
const _lastTabPrefix = 'last_tab_';
const _emojiPalettePrefix = 'emoji_palette_';
const _emojiReactionPalettePrefix = 'emoji_reaction_palette_';
const _pinnedHashtagsPrefix = 'pinned_hashtags_';
const _hideLivecureKey = 'hide_livecure';
const _mfmAnimationKey = 'mfm_animation_enabled';
const _themeModeKey = 'theme_mode';
const _absoluteTimeKey = 'absolute_time';
const _blurAllImagesKey = 'blur_all_images';
const _hideInstanceTickerKey = 'hide_instance_ticker';
const _restoreReadPositionKey = 'restore_read_position';
const _confirmBeforePostKey = 'confirm_before_post';
const _hiddenListIdsPrefix = 'hidden_list_ids_';
const _listOrderPrefix = 'list_order_';
const _hiddenTimelineTypesPrefix = 'hidden_timeline_types_';
const _previewCardModeKey = 'preview_card_mode';
const _emojiScaleKey = 'emoji_scale';
const _thumbnailScaleKey = 'thumbnail_scale';
const _backgroundImagePathKey = 'background_image_path';
const _backgroundOpacityKey = 'background_opacity';
const _insertPickerHeightKey = 'insert_picker_height';
const _recentEmojisKey = 'recent_emojis';
const _composeTemplateHistoryKey = 'compose_template_history';
const _emojiZeroWidthSpaceKey = 'emoji_zero_width_space';
const _darkSurfaceVariantKey = 'dark_surface_variant';
const _tabConfigPrefix = 'tab_config_';
const _avatarShapeKey = 'avatar_shape';
const _mouseDragScrollKey = 'mouse_drag_scroll';
const _updateCheckEnabledKey = 'update_check_enabled';
const _residentModeKey = 'resident_mode';
const _launchAtLoginKey = 'launch_at_login';
const _postTouchActionsKey = 'post_touch_actions';
const _nowPlayingUrlProviderKey = 'nowplaying_url_provider';
const _showStreamReconnectDetailKey = 'show_stream_reconnect_detail';

/// Display mode for OGP preview cards.
enum PreviewCardMode {
  /// Show preview cards normally.
  show,

  /// Blur the preview card image.
  blur,

  /// Hide preview cards entirely.
  hide,
}

/// ナウプレ URL の優先プロバイダ (#681)。URL を持たないナウプレ源
/// (Apple Music / MPRIS / SMTC) を enrich (#669) で共有 URL 解決する際、
/// どちらの配信元の URL を載せたいかのユーザー嗜好。端末ローカル設定で、
/// モロヘイヤ enrich 呼び出しの `prefer` パラメータとして毎回送る。既定は
/// Apple Music（運営者の価値観＝アーティスト還元、サーバー既定とも一致）。
enum NowPlayingUrlProvider {
  appleMusic,
  spotify;

  /// モロヘイヤ enrich の `prefer` パラメータ値。
  String get apiValue => switch (this) {
    NowPlayingUrlProvider.appleMusic => 'apple_music',
    NowPlayingUrlProvider.spotify => 'spotify',
  };
}

/// アカウントアイコンの形状 (#372)。
///
/// auto: #371 で確立した「Misskey 由来 (isCat または ReactionSupport adapter)
/// なら丸、それ以外は角丸」のフォールバック。
/// circle: 強制的に丸 (size/2)。
/// squircle: 強制的に角丸 (UserAvatar の borderRadius を使用)。猫耳 / アイコン
/// デコの座標計算は丸前提のため、squircle 選択時は位置ずれが生じる仕様
/// (詳細は #372 のコメント参照)。
enum AvatarShape { auto, circle, squircle }

/// Default font scale factor (1.0 = system default).
const defaultFontScale = 1.0;

/// Minimum / maximum font scale.
const minFontScale = 0.8;
const maxFontScale = 1.4;

/// Step size for font scale slider.
const fontScaleStep = 0.1;

/// Provides the current font scale factor.
///
/// Reads from SharedPreferences on first access and notifies listeners on
/// changes, so the entire app rebuilds with the new text size.
final fontScaleProvider = NotifierProvider<FontScaleNotifier, double>(
  FontScaleNotifier.new,
);

/// Default custom emoji size in logical pixels.
const defaultEmojiSize = 20.0;

/// Minimum / maximum emoji size.
const minEmojiSize = 16.0;
const maxEmojiSize = 40.0;

/// Step size for emoji size slider.
const emojiSizeStep = 2.0;

/// Provides the current custom emoji size.
final emojiSizeProvider = NotifierProvider<EmojiSizeNotifier, double>(
  EmojiSizeNotifier.new,
);

/// Default thumbnail scale factor (1.0 = original size).
const defaultThumbnailScale = 1.0;

/// Minimum / maximum thumbnail scale.
const minThumbnailScale = 0.4;
const maxThumbnailScale = 1.2;

/// Step size for thumbnail scale slider.
const thumbnailScaleStep = 0.1;

/// Provides the current thumbnail scale factor.
final thumbnailScaleProvider = NotifierProvider<ThumbnailScaleNotifier, double>(
  ThumbnailScaleNotifier.new,
);

/// Preset colors for the theme color picker.
const themeColorPresets = [
  Colors.red,
  Colors.pink,
  Colors.purple,
  Colors.deepPurple,
  Colors.indigo,
  Colors.blue,
  Colors.lightBlue,
  Colors.cyan,
  Colors.teal,
  Colors.green,
  Colors.lightGreen,
  Colors.lime,
  Colors.yellow,
  Colors.amber,
  Colors.orange,
  Colors.deepOrange,
  Colors.brown,
  Colors.blueGrey,
];

/// Per-account theme color override.
///
/// Takes an account storage key as the family parameter.
/// Returns null when the user has not set a custom color (use server default).
final accountThemeColorProvider =
    NotifierProvider.family<AccountThemeColorNotifier, Color?, String>(
      AccountThemeColorNotifier.new,
    );

class AccountThemeColorNotifier extends FamilyNotifier<Color?, String> {
  @override
  Color? build(String arg) {
    _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('$_themeColorPrefix$arg');
    if (saved != null) {
      state = Color(saved);
    }
  }

  Future<void> setColor(Color? color) async {
    state = color;
    final prefs = await SharedPreferences.getInstance();
    if (color != null) {
      await prefs.setInt('$_themeColorPrefix$arg', color.toARGB32());
    } else {
      await prefs.remove('$_themeColorPrefix$arg');
    }
  }
}

/// Per-account last selected tab persistence.
///
/// Stores the tab the user was viewing when the app was last used, so it can
/// be restored on the next launch.  The value is a single string:
///   - `timeline:<name>`  (e.g. `timeline:home`)
///   - `list:<id>`
///   - `hashtag:<tag>`
final lastTabProvider =
    NotifierProvider.family<LastTabNotifier, String?, String>(
      LastTabNotifier.new,
    );

class LastTabNotifier extends FamilyNotifier<String?, String> {
  /// build() 中に走った _load() の SharedPreferences.getInstance() await は
  /// 初回起動で遅く、その間に login_screen 等が save() を呼ぶと、後から
  /// 解決した _load() が disk の旧値で明示選択を無条件上書きしてしまう
  /// (#579: misskey.io でホームのつもりがローカルになる間欠不具合)。
  /// 明示 save() があったら _load() は復元をスキップし「後勝ち」を防ぐ。
  bool _explicitlySet = false;

  @override
  String? build(String arg) {
    _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // await 中に save() が走っていれば、その明示選択を尊重して復元しない。
    if (_explicitlySet) return;
    final saved = prefs.getString('$_lastTabPrefix$arg');
    if (saved != null && !_explicitlySet) {
      state = saved;
    }
  }

  Future<void> save(String value) async {
    _explicitlySet = true;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_lastTabPrefix$arg', value);
  }
}

// ---------------------------------------------------------------------------
// Unified tab configuration (order + visibility for all tab types).
// ---------------------------------------------------------------------------

/// Default tab entries for a fresh install.
///
/// Notifications and announcements are hidden by default (Issue #281).
const defaultTabConfig = [
  TabConfigEntry(tab: TimelineTab(TimelineType.home), visible: true),
  TabConfigEntry(tab: TimelineTab(TimelineType.local), visible: true),
  TabConfigEntry(tab: TimelineTab(TimelineType.social), visible: true),
  TabConfigEntry(tab: TimelineTab(TimelineType.federated), visible: true),
  TabConfigEntry(tab: TimelineTab(TimelineType.directMessages), visible: true),
  TabConfigEntry(tab: NotificationsTab(), visible: false),
  TabConfigEntry(tab: AnnouncementsTab(), visible: false),
  // Misskey 限定。ChatSupport 不在アダプタでは tab_management_sheet 側で
  // フィルタされて表示されない (#439)。
  TabConfigEntry(tab: MessagesTab(), visible: false),
];

/// A single entry in the tab configuration: a tab and its visibility.
class TabConfigEntry {
  final TabType tab;
  final bool visible;
  const TabConfigEntry({required this.tab, required this.visible});

  TabConfigEntry copyWith({bool? visible}) =>
      TabConfigEntry(tab: tab, visible: visible ?? this.visible);
}

/// Per-account unified tab configuration.
///
/// Takes an account storage key as the family parameter.
/// Handles migration from the legacy per-type providers on first load.
final tabConfigProvider =
    NotifierProvider.family<TabConfigNotifier, List<TabConfigEntry>, String>(
      TabConfigNotifier.new,
    );

class TabConfigNotifier extends FamilyNotifier<List<TabConfigEntry>, String> {
  @override
  List<TabConfigEntry> build(String arg) {
    // pre-warm 済み SharedPreferences から同期で読む (#579)。build() が
    // 同期戻りした直後に visibleTabsProvider が解決するため、ここで非同期
    // ロードを挟むと「pre-migrate の defaultTabConfig が一瞬見える → social
    // 化する」race が発生する。main() で initSharedPreferencesCache() を呼ぶ
    // 前提で同期化している。
    final prefs = sharedPrefsOrThrow;
    final saved = prefs.getStringList('$_tabConfigPrefix$arg');
    if (saved != null) {
      return _deserialize(saved);
    }
    // Migrate from legacy providers (synchronous).
    final entries = _migrate(prefs);
    // 永続化は fire-and-forget。失敗しても次回起動で再度 migrate するだけで
    // ユーザー影響なし (idempotent)。await すると build() が async 化して
    // race が復活するため意図的に unawaited。
    unawaited(
      prefs.setStringList('$_tabConfigPrefix$arg', _serialize(entries)),
    );
    return entries;
  }

  /// Migrate from the legacy per-type preferences into the unified format.
  List<TabConfigEntry> _migrate(SharedPreferences prefs) {
    final entries = <TabConfigEntry>[];

    // 1. Timeline tabs (order + hidden).
    final savedOrder = prefs.getStringList('$_tabOrderPrefix$arg');
    final savedHidden =
        prefs.getStringList('$_hiddenTimelineTypesPrefix$arg')?.toSet() ??
        const <String>{};
    final timelineOrder = savedOrder != null
        ? savedOrder
              .map(
                (n) =>
                    TimelineType.values.where((t) => t.name == n).firstOrNull,
              )
              .whereType<TimelineType>()
              .toList()
        : List<TimelineType>.from(defaultTabOrder);
    // Append any timeline types missing from the saved order.
    for (final t in defaultTabOrder) {
      if (!timelineOrder.contains(t)) timelineOrder.add(t);
    }
    for (final t in timelineOrder) {
      entries.add(
        TabConfigEntry(
          tab: TimelineTab(t),
          visible: !savedHidden.contains(t.name),
        ),
      );
    }

    // 2. List tabs (order + hidden).
    final savedListOrder = prefs.getStringList('$_listOrderPrefix$arg');
    final savedHiddenLists =
        prefs.getStringList('$_hiddenListIdsPrefix$arg')?.toSet() ??
        const <String>{};
    if (savedListOrder != null) {
      for (final id in savedListOrder) {
        entries.add(
          TabConfigEntry(
            tab: ListTab(id: id),
            visible: !savedHiddenLists.contains(id),
          ),
        );
      }
    }

    // 3. Hashtag tabs (pinned = always visible).
    final savedHashtags = prefs.getStringList('$_pinnedHashtagsPrefix$arg');
    if (savedHashtags != null) {
      for (final tag in savedHashtags) {
        entries.add(TabConfigEntry(tab: HashtagTab(tag), visible: true));
      }
    }

    // 4. Notifications & announcements (default hidden for existing users).
    entries.add(const TabConfigEntry(tab: NotificationsTab(), visible: false));
    entries.add(const TabConfigEntry(tab: AnnouncementsTab(), visible: false));
    // Messages tab — Misskey 限定動線 (#439)。デフォルト hidden。
    entries.add(const TabConfigEntry(tab: MessagesTab(), visible: false));

    // 永続化は build() 側で fire-and-forget。ここで await すると build() が
    // async 化して #579 の race が復活するため、entries 構築のみに留める。
    return entries;
  }

  static List<TabConfigEntry> _deserialize(List<String> raw) {
    final entries = <TabConfigEntry>[];
    for (final s in raw) {
      final hidden = s.startsWith('!');
      final key = hidden ? s.substring(1) : s;
      final tab = TabType.fromKey(key);
      if (tab != null) {
        entries.add(TabConfigEntry(tab: tab, visible: !hidden));
      }
    }
    return entries;
  }

  static List<String> _serialize(List<TabConfigEntry> entries) => entries
      .map((e) => e.visible ? e.tab.toKey() : '!${e.tab.toKey()}')
      .toList();

  Future<void> _save(
    List<TabConfigEntry> entries, [
    SharedPreferences? prefs,
  ]) async {
    prefs ??= await SharedPreferences.getInstance();
    await prefs.setStringList('$_tabConfigPrefix$arg', _serialize(entries));
  }

  /// Toggle visibility of a tab.
  Future<void> toggleVisibility(TabType tab) async {
    state = [
      for (final e in state)
        if (e.tab == tab) e.copyWith(visible: !e.visible) else e,
    ];
    await _save(state);
  }

  /// Reorder all entries.
  Future<void> setOrder(List<TabConfigEntry> entries) async {
    state = entries;
    await _save(entries);
  }

  /// Add a new tab (e.g., a newly pinned hashtag or a new list).
  /// Appended at the end, visible by default.
  Future<void> addTab(TabType tab, {bool visible = true}) async {
    if (state.any((e) => e.tab == tab)) return;
    state = [...state, TabConfigEntry(tab: tab, visible: visible)];
    await _save(state);
  }

  /// Remove a tab (e.g., unpinning a hashtag or deleting a list).
  Future<void> removeTab(TabType tab) async {
    state = state.where((e) => e.tab != tab).toList();
    await _save(state);
  }

  /// Replace a tab entry (e.g., renaming a hashtag AND condition).
  Future<void> replaceTab(TabType oldTab, TabType newTab) async {
    state = [
      for (final e in state)
        if (e.tab == oldTab)
          TabConfigEntry(tab: newTab, visible: e.visible)
        else
          e,
    ];
    await _save(state);
  }

  /// Update the name cached in a [ListTab] entry.
  void syncListName(String listId, String name) {
    final updated = [
      for (final e in state)
        if (e.tab is ListTab && (e.tab as ListTab).id == listId)
          TabConfigEntry(
            tab: ListTab(id: listId, name: name),
            visible: e.visible,
          )
        else
          e,
    ];
    if (updated != state) {
      state = updated;
      _save(updated);
    }
  }
}

/// Visible tabs in display order, derived from [tabConfigProvider].
///
/// Timeline tabs whose type is not supported by the current adapter
/// (e.g. social on Mastodon, directMessages on Misskey) are excluded.
/// List tabs whose list no longer exists on the server are also excluded.
/// Channel tabs whose ID is not present on the current server are also
/// excluded (#464 — Misskey 同士でも別サーバーの ChannelTab が残存表示
/// される問題対策。ListTab と同型に揃える)。
/// Server lists not yet in the config are appended automatically.
final visibleTabsProvider = Provider.family<List<TabType>, String>((
  ref,
  storageKey,
) {
  final adapter = ref.watch(currentAdapterProvider);
  final supported =
      adapter?.capabilities.supportedTimelines ??
      {TimelineType.home, TimelineType.local, TimelineType.federated};
  final serverLists = ref.watch(listsProvider).valueOrNull ?? [];
  final serverListIds = serverLists.map((l) => l.id).toSet();
  // 現サーバーのフォロー中チャンネル ID 集合。followedChannelsProvider が
  // まだ resolve していない (loading) 段階では `null` のままで、capability
  // チェックだけにフォールバックする (前アカウントの古い ChannelTab を
  // 切るのが目的なので、loading 中の誤判定で正規チャンネルを消すのを避ける)。
  final serverChannelsAsync = ref.watch(followedChannelsProvider);
  final serverChannelIds = serverChannelsAsync.valueOrNull
      ?.map((c) => c.id)
      .toSet();
  final config = ref.watch(tabConfigProvider(storageKey));

  final tabs = config.where((e) => e.visible).map((e) => e.tab).where((tab) {
    if (tab is TimelineTab) return supported.contains(tab.type);
    if (tab is ListTab) return serverListIds.contains(tab.id);
    if (tab is ChannelTab) {
      if (adapter is! ChannelSupport) return false;
      // serverChannelIds が未確定 (初回ロード前) の間は capability 判定の
      // みでフォールバック。確定後に本フィルタが効いて他サーバー由来の
      // ChannelTab が消える。
      if (serverChannelIds == null) return true;
      return serverChannelIds.contains(tab.id);
    }
    return true;
  }).toList();

  // Append server lists not yet tracked in the config.
  final configListIds = config
      .where((e) => e.tab is ListTab)
      .map((e) => (e.tab as ListTab).id)
      .toSet();
  for (final list in serverLists) {
    if (!configListIds.contains(list.id)) {
      tabs.add(ListTab(id: list.id, name: list.title));
    }
  }

  // Append followed channels not yet tracked in the config (#666 — channel
  // tabs were only synced when the tab management sheet opened, so they did
  // not appear right after login. Mirror the list behaviour above so they
  // show as soon as followedChannelsProvider resolves). Channels the user
  // explicitly hid are already in `config` (visible == false) and thus in
  // configChannelIds, so they are not re-appended.
  if (adapter is ChannelSupport && serverChannelIds != null) {
    final configChannelIds = config
        .where((e) => e.tab is ChannelTab)
        .map((e) => (e.tab as ChannelTab).id)
        .toSet();
    final followedChannels = serverChannelsAsync.valueOrNull ?? const [];
    for (final ch in followedChannels) {
      if (!configChannelIds.contains(ch.id)) {
        tabs.add(ChannelTab(id: ch.id, name: ch.name));
      }
    }
  }

  return tabs;
});

/// Whether a specific tab type is currently visible.
final isTabVisibleProvider =
    Provider.family<bool, ({String storageKey, TabType tab})>((ref, args) {
      return ref
          .watch(tabConfigProvider(args.storageKey))
          .any((e) => e.tab == args.tab && e.visible);
    });

// ---------------------------------------------------------------------------
// Legacy tab providers (kept for migration; new code should use
// tabConfigProvider).
// ---------------------------------------------------------------------------

/// Default tab order for timelines.
const defaultTabOrder = [
  TimelineType.home,
  TimelineType.local,
  TimelineType.social,
  TimelineType.federated,
  TimelineType.directMessages,
];

/// Per-account tab order preference.
///
/// Takes an account storage key as the family parameter.
/// Returns the default order when the user has not customized it.
final tabOrderProvider =
    NotifierProvider.family<TabOrderNotifier, List<TimelineType>, String>(
      TabOrderNotifier.new,
    );

class TabOrderNotifier extends FamilyNotifier<List<TimelineType>, String> {
  @override
  List<TimelineType> build(String arg) {
    _load();
    return defaultTabOrder;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('$_tabOrderPrefix$arg');
    if (saved != null) {
      final order = saved
          .map(
            (name) =>
                TimelineType.values.where((t) => t.name == name).firstOrNull,
          )
          .whereType<TimelineType>()
          .toList();
      // Append any new timeline types that weren't in the saved order.
      for (final t in defaultTabOrder) {
        if (!order.contains(t)) order.add(t);
      }
      if (order.isNotEmpty) state = order;
    }
  }

  Future<void> setOrder(List<TimelineType> order) async {
    state = order;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      '$_tabOrderPrefix$arg',
      order.map((t) => t.name).toList(),
    );
  }

  Future<void> reset() async {
    state = defaultTabOrder;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_tabOrderPrefix$arg');
  }
}

/// Per-host emoji palette for compose (main).
///
/// Takes a hostname as the family parameter.
/// Returns an empty list when no palette has been imported.
final emojiPaletteProvider =
    NotifierProvider.family<EmojiPaletteNotifier, List<String>, String>(
      EmojiPaletteNotifier.new,
    );

/// Per-host emoji palette for reactions.
///
/// Takes a hostname as the family parameter.
/// Falls back to the main palette when no reaction palette is set.
final emojiReactionPaletteProvider =
    NotifierProvider.family<EmojiReactionPaletteNotifier, List<String>, String>(
      EmojiReactionPaletteNotifier.new,
    );

class EmojiPaletteNotifier extends FamilyNotifier<List<String>, String> {
  @override
  List<String> build(String arg) {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('$_emojiPalettePrefix$arg');
    if (saved != null && saved.isNotEmpty) {
      state = saved;
    }
  }

  Future<void> importFromText(String text) async {
    final shortcodes = _parseShortcodes(text);
    if (shortcodes.isEmpty) return;
    state = shortcodes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_emojiPalettePrefix$arg', shortcodes);
  }

  /// Replace the palette with server-fetched entries.
  Future<void> importFromServer(List<String> emojis) async {
    if (emojis.isEmpty) return;
    state = emojis;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_emojiPalettePrefix$arg', emojis);
  }

  Future<void> clear() async {
    state = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_emojiPalettePrefix$arg');
  }

  /// Parse `:shortcode:` entries and bare unicode emoji from pasted text.
  static List<String> _parseShortcodes(String text) {
    final results = <String>[];
    final pattern = RegExp(r':[a-zA-Z0-9_@.\-]+:');
    final matches = pattern.allMatches(text);
    for (final m in matches) {
      results.add(m.group(0)!);
    }
    // If no shortcodes found, try splitting by whitespace (unicode emoji).
    if (results.isEmpty) {
      final parts = text.trim().split(RegExp(r'\s+'));
      for (final p in parts) {
        if (p.isNotEmpty) results.add(p);
      }
    }
    return results;
  }
}

class EmojiReactionPaletteNotifier
    extends FamilyNotifier<List<String>, String> {
  @override
  List<String> build(String arg) {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('$_emojiReactionPalettePrefix$arg');
    if (saved != null && saved.isNotEmpty) {
      state = saved;
    }
  }

  Future<void> importFromServer(List<String> emojis) async {
    if (emojis.isEmpty) return;
    state = emojis;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_emojiReactionPalettePrefix$arg', emojis);
  }

  Future<void> clear() async {
    state = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_emojiReactionPalettePrefix$arg');
  }
}

/// Recently used emojis (both custom and unicode, app-wide).
const _recentEmojisLimit = 30;

final recentEmojisProvider =
    NotifierProvider<RecentEmojisNotifier, List<String>>(
      RecentEmojisNotifier.new,
    );

class RecentEmojisNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_recentEmojisKey);
    if (saved != null && saved.isNotEmpty) {
      state = saved;
    }
  }

  Future<void> add(String emoji) async {
    final updated = [emoji, ...state.where((e) => e != emoji)];
    state = updated.take(_recentEmojisLimit).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentEmojisKey, state);
  }
}

/// 投稿テンプレートの使用履歴 (#767)。最近使ったテンプレートの id を新しい順に
/// 保持し、選択シートで「最近使った順」に並べるために使う。本体（名前・本文）は
/// サーバー（モロヘイヤ）が正で、ここには順序ヒントとして id だけを置く。
final composeTemplateHistoryProvider =
    NotifierProvider<ComposeTemplateHistoryNotifier, List<String>>(
      ComposeTemplateHistoryNotifier.new,
    );

class ComposeTemplateHistoryNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_composeTemplateHistoryKey);
    if (saved != null && saved.isNotEmpty) {
      state = saved;
    }
  }

  /// テンプレートを使ったら先頭へ。件数上限は設けない（テンプレ自体が
  /// サーバー側で最大 50 件に制限されるため）。
  Future<void> touch(String id) async {
    state = [id, ...state.where((e) => e != id)];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_composeTemplateHistoryKey, state);
  }

  /// 現存する id 集合に絞り込む（削除済みテンプレの id を履歴から掃除する）。
  Future<void> retain(Set<String> ids) async {
    final pruned = state.where(ids.contains).toList();
    if (pruned.length == state.length) return;
    state = pruned;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_composeTemplateHistoryKey, state);
  }
}

/// App-wide theme mode (light / dark / system).
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_themeModeKey);
    if (saved != null) {
      final mode = ThemeMode.values.where((m) => m.name == saved).firstOrNull;
      if (mode != null) state = mode;
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.name);
  }
}

/// Whether to hide posts with #実況 hashtag.
final hideLivecureProvider = NotifierProvider<HideLivecureNotifier, bool>(
  HideLivecureNotifier.new,
);

/// MFM のアニメーション（`$[bounce]`/`$[spin]`/`$[shake]` 等）を再生するか
/// (#259)。既定は ON（Misskey に倣う）。動きが煩わしいユーザーは OFF にできる
/// オプトアウト方式。OS の「視差効果を減らす」(reduce motion) が有効なときは
/// 描画側でこの設定に関わらず静止表示する。
final mfmAnimationEnabledProvider =
    NotifierProvider<MfmAnimationEnabledNotifier, bool>(
      MfmAnimationEnabledNotifier.new,
    );

class MfmAnimationEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_mfmAnimationKey);
    if (saved != null) state = saved;
  }

  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mfmAnimationKey, value);
  }
}

class HideLivecureNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_hideLivecureKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hideLivecureKey, state);
  }

  Future<void> setHidden(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hideLivecureKey, value);
  }
}

/// Drawer / TabBar 等の横スクロール要素をマウスドラッグでも掴めるように
/// するか (#574)。OFF (default) なら従来通り mouse / trackpad はホイール
/// 操作のみで、ドラッグはタッチ / スタイラスに限定。ON にすると mouse も
/// dragDevices に追加され「掴んで横へ引く」操作が可能になる代わりに、
/// macOS / Linux のトラックパッド 2 本指スワイプとの両立が崩れるケースが
/// あるため明示的なオプトイン扱い。
final mouseDragScrollProvider = NotifierProvider<MouseDragScrollNotifier, bool>(
  MouseDragScrollNotifier.new,
);

class MouseDragScrollNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_mouseDragScrollKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mouseDragScrollKey, value);
  }
}

/// 接続インジケータで再接続の詳細 (再接続回数バッジ + 直近切断時刻) を出すか
/// (#786)。default OFF。切断・再接続はストリーミングのごく普通の挙動で、回数が
/// 増えても不具合ではない。一般ユーザーには「壊れている？」と誤解させる逆効果の
/// ため既定では隠し、診断したい人だけ ON にする。フラッシュ (速い再接続の橙
/// ラッチ) と接続状態そのものは常時表示なのでこの設定の影響を受けない。
final showStreamReconnectDetailProvider =
    NotifierProvider<ShowStreamReconnectDetailNotifier, bool>(
      ShowStreamReconnectDetailNotifier.new,
    );

class ShowStreamReconnectDetailNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_showStreamReconnectDetailKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showStreamReconnectDetailKey, value);
  }
}

/// 直配チャネル (Linux AppImage / Windows 自己署名 MSIX) の起動時更新検知
/// を行うか (#641)。default ON。ストア配布ビルドでは
/// `kIsDirectChannelBuild` 側でゲートされて何も起きないため、この設定の
/// 表示自体を直配ビルドに限定する側で出し分ける (UI 側責務)。
final updateCheckEnabledProvider =
    NotifierProvider<UpdateCheckEnabledNotifier, bool>(
      UpdateCheckEnabledNotifier.new,
    );

class UpdateCheckEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    // pre-warm 済み SharedPreferences から同期で読む (#652)。非同期ロードで
    // 初期値 true を返すと、updateCheckProvider がその隙に GitHub 更新
    // チェックを走らせ、オプトアウト済みユーザーでも通信 + 更新スナック
    // バーが出てしまう。#579 / TabConfigNotifier と同じく同期化して race を
    // 構造的に消す。
    return sharedPrefsOrThrow.getBool(_updateCheckEnabledKey) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_updateCheckEnabledKey, value);
  }
}

/// デスクトップ常駐モード (#752)。オンにするとメインウィンドウを閉じても
/// アプリは終了せず、トレイ (Windows / Linux) / メニューバー (macOS) に常駐し、
/// #569 の WebSocket streaming 経由でローカル通知を受け続ける。default OFF。
///
/// ウィンドウの閉じる傍受 (setPreventClose) を起動直後に設定する必要があるため
/// 同期ロードする (#652 / #715 / #746 と同じ pre-warm prefs パターン)。非同期
/// ロードだと閉じる操作の初回だけ傍受が間に合わず終了してしまう。
final residentModeProvider = NotifierProvider<ResidentModeNotifier, bool>(
  ResidentModeNotifier.new,
);

class ResidentModeNotifier extends Notifier<bool> {
  @override
  bool build() {
    return sharedPrefsOrThrow.getBool(_residentModeKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_residentModeKey, value);
  }
}

/// デスクトップのログイン時起動 (#751)。OS のログイン項目への登録は
/// `LaunchAtLoginService` 側で行い、ここは pref の真実源だけを持つ
/// （値変化を main の ref.listen で OS に反映する）。default OFF。
final launchAtLoginProvider = NotifierProvider<LaunchAtLoginNotifier, bool>(
  LaunchAtLoginNotifier.new,
);

class LaunchAtLoginNotifier extends Notifier<bool> {
  @override
  bool build() {
    return sharedPrefsOrThrow.getBool(_launchAtLoginKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_launchAtLoginKey, value);
  }
}

/// Per-account pinned hashtags for home screen tabs.
///
/// Takes an account storage key as the family parameter.
final pinnedHashtagsProvider =
    NotifierProvider.family<PinnedHashtagsNotifier, List<String>, String>(
      PinnedHashtagsNotifier.new,
    );

class PinnedHashtagsNotifier extends FamilyNotifier<List<String>, String> {
  @override
  List<String> build(String arg) {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('$_pinnedHashtagsPrefix$arg');
    if (saved != null && saved.isNotEmpty) {
      state = saved;
    }
  }

  Future<void> add(String hashtag) async {
    final tag = hashtag.replaceFirst(RegExp('^#'), '');
    if (tag.isEmpty || state.contains(tag)) return;
    state = [...state, tag];
    await _save();
  }

  Future<void> remove(String hashtag) async {
    state = state.where((t) => t != hashtag).toList();
    await _save();
  }

  Future<void> replace(String oldSpec, String newSpec) async {
    if (oldSpec == newSpec) return;
    state = state.map((t) => t == oldSpec ? newSpec : t).toList();
    await _save();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = [...state];
    final item = list.removeAt(oldIndex);
    if (newIndex > oldIndex) newIndex--;
    list.insert(newIndex, item);
    state = list;
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_pinnedHashtagsPrefix$arg', state);
  }
}

/// Display mode for OGP preview cards.
final previewCardModeProvider =
    NotifierProvider<PreviewCardModeNotifier, PreviewCardMode>(
      PreviewCardModeNotifier.new,
    );

class PreviewCardModeNotifier extends Notifier<PreviewCardMode> {
  @override
  PreviewCardMode build() {
    _load();
    return PreviewCardMode.show;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_previewCardModeKey);
    if (saved != null) {
      final mode = PreviewCardMode.values
          .where((m) => m.name == saved)
          .firstOrNull;
      if (mode != null) state = mode;
    }
  }

  Future<void> setMode(PreviewCardMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_previewCardModeKey, mode.name);
  }
}

/// ナウプレ URL の優先プロバイダ設定 (#681)。既定は Apple Music。
final nowPlayingUrlProviderProvider =
    NotifierProvider<NowPlayingUrlProviderNotifier, NowPlayingUrlProvider>(
      NowPlayingUrlProviderNotifier.new,
    );

class NowPlayingUrlProviderNotifier extends Notifier<NowPlayingUrlProvider> {
  @override
  NowPlayingUrlProvider build() {
    _load();
    return NowPlayingUrlProvider.appleMusic;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_nowPlayingUrlProviderKey);
    if (saved != null) {
      final provider = NowPlayingUrlProvider.values
          .where((p) => p.name == saved)
          .firstOrNull;
      if (provider != null) state = provider;
    }
  }

  Future<void> setProvider(NowPlayingUrlProvider provider) async {
    state = provider;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nowPlayingUrlProviderKey, provider.name);
  }
}

/// アカウントアイコンの形状設定 (#372)。
final avatarShapeProvider = NotifierProvider<AvatarShapeNotifier, AvatarShape>(
  AvatarShapeNotifier.new,
);

class AvatarShapeNotifier extends Notifier<AvatarShape> {
  @override
  AvatarShape build() {
    _load();
    return AvatarShape.auto;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_avatarShapeKey);
    if (saved != null) {
      final shape = AvatarShape.values
          .where((s) => s.name == saved)
          .firstOrNull;
      if (shape != null) state = shape;
    }
  }

  Future<void> setShape(AvatarShape shape) async {
    state = shape;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_avatarShapeKey, shape.name);
  }
}

/// Per-account hidden list IDs.
final hiddenListIdsProvider =
    NotifierProvider.family<HiddenListIdsNotifier, Set<String>, String>(
      HiddenListIdsNotifier.new,
    );

class HiddenListIdsNotifier extends FamilyNotifier<Set<String>, String> {
  @override
  Set<String> build(String arg) {
    _load();
    return const {};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('$_hiddenListIdsPrefix$arg');
    if (saved != null && saved.isNotEmpty) {
      state = saved.toSet();
    }
  }

  Future<void> toggle(String listId) async {
    if (state.contains(listId)) {
      state = {...state}..remove(listId);
    } else {
      state = {...state, listId};
    }
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_hiddenListIdsPrefix$arg', state.toList());
  }
}

/// Per-account hidden timeline types.
final hiddenTimelineTypesProvider =
    NotifierProvider.family<
      HiddenTimelineTypesNotifier,
      Set<TimelineType>,
      String
    >(HiddenTimelineTypesNotifier.new);

class HiddenTimelineTypesNotifier
    extends FamilyNotifier<Set<TimelineType>, String> {
  @override
  Set<TimelineType> build(String arg) {
    _load();
    return const {};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('$_hiddenTimelineTypesPrefix$arg');
    if (saved != null && saved.isNotEmpty) {
      state = saved
          .map(
            (name) =>
                TimelineType.values.where((t) => t.name == name).firstOrNull,
          )
          .whereType<TimelineType>()
          .toSet();
    }
  }

  Future<void> toggle(TimelineType type) async {
    if (state.contains(type)) {
      state = {...state}..remove(type);
    } else {
      state = {...state, type};
    }
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      '$_hiddenTimelineTypesPrefix$arg',
      state.map((t) => t.name).toList(),
    );
  }
}

/// Per-account list display order.
final listOrderProvider =
    NotifierProvider.family<ListOrderNotifier, List<String>, String>(
      ListOrderNotifier.new,
    );

class ListOrderNotifier extends FamilyNotifier<List<String>, String> {
  @override
  List<String> build(String arg) {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('$_listOrderPrefix$arg');
    if (saved != null && saved.isNotEmpty) {
      state = saved;
    }
  }

  Future<void> setOrder(List<String> order) async {
    state = order;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_listOrderPrefix$arg', order);
  }
}

/// Whether to show a confirmation dialog before posting.
final confirmBeforePostProvider =
    NotifierProvider<ConfirmBeforePostNotifier, bool>(
      ConfirmBeforePostNotifier.new,
    );

class ConfirmBeforePostNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_confirmBeforePostKey);
    if (saved != null) {
      state = saved;
    }
  }

  /// Returns the persisted value directly from SharedPreferences.
  ///
  /// Use this instead of synchronous [state] when the value must reflect
  /// the saved preference regardless of whether [_load] has completed.
  Future<bool> readPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_confirmBeforePostKey) ?? false;
    state = value;
    return value;
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_confirmBeforePostKey, state);
  }
}

/// Whether to blur all images regardless of NSFW flag.
final blurAllImagesProvider = NotifierProvider<BlurAllImagesNotifier, bool>(
  BlurAllImagesNotifier.new,
);

class BlurAllImagesNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_blurAllImagesKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_blurAllImagesKey, state);
  }
}

/// Whether to hide the instance ticker (source-server band) on remote posts.
final hideInstanceTickerProvider =
    NotifierProvider<HideInstanceTickerNotifier, bool>(
      HideInstanceTickerNotifier.new,
    );

class HideInstanceTickerNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_hideInstanceTickerKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hideInstanceTickerKey, state);
  }
}

/// Whether to restore the saved read position (#25 markers) on cold start.
/// Default is on (restore). When off, the home timeline always opens at the
/// newest post. Mastodon-only behavior (markers API); Misskey always opens at
/// the top regardless.
final restoreReadPositionProvider =
    NotifierProvider<RestoreReadPositionNotifier, bool>(
      RestoreReadPositionNotifier.new,
    );

class RestoreReadPositionNotifier extends Notifier<bool> {
  @override
  bool build() {
    // pre-warm 済み SharedPreferences から同期で読む (#746)。非同期ロードで
    // 初期値 true を返すと、HomeScreen._restoreMarker が _load 完了前に
    // 同期参照し、OFF 設定者でも getMarkers → 旧読み位置へジャンプしてしまう
    // race になる。#579 / #652 と同じく同期化して race を構造的に消す。
    return sharedPrefsOrThrow.getBool(_restoreReadPositionKey) ?? true;
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_restoreReadPositionKey, state);
  }
}

/// 挿入ピッカーシートの高さ（利用可能領域に対する比率）。ユーザーが上端の
/// ハンドルをドラッグして決めた値を記憶し、次回も同じ高さで開く (#690)。
/// ドラッグ側の clamp と揃えるため公開定数にしている。
const double kMinInsertPickerHeight = 0.25;
const double kMaxInsertPickerHeight = 0.9;
const double kDefaultInsertPickerHeight = 0.5;

final insertPickerHeightProvider =
    NotifierProvider<InsertPickerHeightNotifier, double>(
      InsertPickerHeightNotifier.new,
    );

class InsertPickerHeightNotifier extends Notifier<double> {
  @override
  double build() {
    _load();
    return kDefaultInsertPickerHeight;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_insertPickerHeightKey);
    if (saved != null) {
      state = saved.clamp(kMinInsertPickerHeight, kMaxInsertPickerHeight);
    }
  }

  Future<void> set(double value) async {
    final clamped = value.clamp(kMinInsertPickerHeight, kMaxInsertPickerHeight);
    state = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_insertPickerHeightKey, clamped);
  }
}

/// Whether to show absolute timestamps instead of relative ones.
final absoluteTimeProvider = NotifierProvider<AbsoluteTimeNotifier, bool>(
  AbsoluteTimeNotifier.new,
);

class AbsoluteTimeNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_absoluteTimeKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_absoluteTimeKey, state);
  }
}

/// タイムライン上の投稿タイルに直接表示する「タッチ操作」ボタンの種別 (#565)。
///
/// 既定では誤タッチ防止のため全アクションが長押しメニュー（および右上の
/// 「…」ボタン）からのみ操作可能だが、端末ごと・アクション別にオプトインで
/// タイル上の小ボタンを露出できる。Mastodon / Misskey の機能差は描画側で
/// adapter の mixin (FavoriteSupport / ReactionSupport) を見て出し分ける。
///
/// ブックマーク（Misskey では「お気に入り」= i/favorites）はタッチ操作に
/// 含めない: ブックマーク操作はモロヘイヤが PieFed ブックマークという重い
/// 処理にフックするため、デスクトップでも 1 タップで気軽に走らせたくない
/// （#565 背景の「指が触れて重い処理が走る事故」そのもの）。加えて Misskey は
/// お気に入り状態をタイムラインに返さず二重付与で 400 になる事情もある。
/// ブックマークは長押しメニューからの意図的操作に限定する。
enum PostTouchAction {
  /// リプライ。
  reply,

  /// お気に入り (Mastodon の FavoriteSupport)。
  favorite,

  /// リアクション (Misskey の ReactionSupport)。
  reaction,

  /// ブースト / リノート。
  boost,

  /// 引用。
  quote,
}

/// 投稿タイルでタッチ操作を有効化するアクションの集合 (#565)。
///
/// **端末ごと** (SharedPreferences) に保持し、既定は全アクション OFF
/// （これまでの「誤タッチ防止のため塞ぐ」仕様を尊重）。長押しメニュー /
/// 「…」ボタンは有効・無効に関係なく常に併存する。
final postTouchActionsProvider =
    NotifierProvider<PostTouchActionsNotifier, Set<PostTouchAction>>(
      PostTouchActionsNotifier.new,
    );

class PostTouchActionsNotifier extends Notifier<Set<PostTouchAction>> {
  @override
  Set<PostTouchAction> build() {
    // pre-warm 済み SharedPreferences から同期で読む。非同期ロードにすると
    // 初回描画でボタンが空 → 直後に出現とちらつくため、updateCheckEnabled /
    // TabConfig と同じく同期化する。
    final saved = sharedPrefsOrThrow.getStringList(_postTouchActionsKey);
    if (saved == null) {
      return const <PostTouchAction>{};
    }
    final byName = {for (final a in PostTouchAction.values) a.name: a};
    return saved
        .map((name) => byName[name])
        .whereType<PostTouchAction>()
        .toSet();
  }

  bool isEnabled(PostTouchAction action) => state.contains(action);

  Future<void> setEnabled(PostTouchAction action, bool enabled) async {
    if (state.contains(action) == enabled) {
      return;
    }
    final next = {...state};
    if (enabled) {
      next.add(action);
    } else {
      next.remove(action);
    }
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _postTouchActionsKey,
      state.map((a) => a.name).toList(),
    );
  }
}

class FontScaleNotifier extends Notifier<double> {
  @override
  double build() {
    _load();
    return defaultFontScale;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_fontScaleKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> setScale(double scale) async {
    final clamped = scale.clamp(minFontScale, maxFontScale);
    state = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontScaleKey, clamped);
  }
}

class EmojiSizeNotifier extends Notifier<double> {
  @override
  double build() {
    _load();
    return defaultEmojiSize;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_emojiScaleKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> setSize(double size) async {
    final clamped = size.clamp(minEmojiSize, maxEmojiSize);
    state = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_emojiScaleKey, clamped);
  }
}

class ThumbnailScaleNotifier extends Notifier<double> {
  @override
  double build() {
    _load();
    return defaultThumbnailScale;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_thumbnailScaleKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> setScale(double scale) async {
    final clamped = scale.clamp(minThumbnailScale, maxThumbnailScale);
    state = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_thumbnailScaleKey, clamped);
  }
}

/// Default background opacity.
const defaultBackgroundOpacity = 0.25;
const minBackgroundOpacity = 0.05;
const maxBackgroundOpacity = 0.5;
const backgroundOpacityStep = 0.05;

/// Per-account background image file path (null = no background).
///
/// Takes an account storage key as the family parameter.
/// On first load, migrates the legacy global setting if present.
final backgroundImageProvider =
    NotifierProvider.family<BackgroundImageNotifier, String?, String>(
      BackgroundImageNotifier.new,
    );

class BackgroundImageNotifier extends FamilyNotifier<String?, String> {
  @override
  String? build(String arg) {
    _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_backgroundImagePathKey}_$arg';
    var saved = prefs.getString(key);

    // Migrate legacy global setting.
    // Keep the legacy key so that other accounts can also pick it up.
    if (saved == null) {
      final legacy = prefs.getString(_backgroundImagePathKey);
      if (legacy != null && File(legacy).existsSync()) {
        await prefs.setString(key, legacy);
        saved = legacy;
      }
    }

    if (saved != null && File(saved).existsSync()) {
      state = saved;
    }
  }

  /// Copy the picked image to the app support directory and persist its path.
  Future<void> setImage(String sourcePath) async {
    final old = state;
    final dir = await getApplicationSupportDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeArg = arg.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final dest = '${dir.path}/background_image_${safeArg}_$timestamp.png';
    await File(sourcePath).copy(dest);
    state = dest;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_backgroundImagePathKey}_$arg', dest);
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
  }

  Future<void> clear() async {
    final current = state;
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_backgroundImagePathKey}_$arg');
    if (current != null) {
      try {
        await File(current).delete();
      } catch (_) {}
    }
  }
}

/// Per-account background image opacity.
///
/// Takes an account storage key as the family parameter.
/// On first load, migrates the legacy global setting if present.
final backgroundOpacityProvider =
    NotifierProvider.family<BackgroundOpacityNotifier, double, String>(
      BackgroundOpacityNotifier.new,
    );

class BackgroundOpacityNotifier extends FamilyNotifier<double, String> {
  @override
  double build(String arg) {
    _load();
    return defaultBackgroundOpacity;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_backgroundOpacityKey}_$arg';
    var saved = prefs.getDouble(key);

    // Migrate legacy global setting.
    // Keep the legacy key so that other accounts can also pick it up.
    if (saved == null) {
      final legacy = prefs.getDouble(_backgroundOpacityKey);
      if (legacy != null) {
        await prefs.setDouble(key, legacy);
        saved = legacy;
      }
    }

    if (saved != null) {
      state = saved;
    }
  }

  Future<void> setOpacity(double opacity) async {
    final clamped = opacity.clamp(minBackgroundOpacity, maxBackgroundOpacity);
    state = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('${_backgroundOpacityKey}_$arg', clamped);
  }
}

/// Whether to use zero-width space instead of regular space around custom emoji.
final emojiZeroWidthSpaceProvider =
    NotifierProvider<EmojiZeroWidthSpaceNotifier, bool>(
      EmojiZeroWidthSpaceNotifier.new,
    );

class EmojiZeroWidthSpaceNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_emojiZeroWidthSpaceKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_emojiZeroWidthSpaceKey, state);
  }
}

/// Preset dark surface colors.
enum DarkSurfaceVariant {
  /// Default (Material 3 generated).
  standard,

  /// Pure black (OLED).
  oled,

  /// Dark gray.
  darkGray,

  /// Warm dark brown.
  warmDark,

  /// Cool dark blue.
  coolDark,
}

const _darkSurfaceColors = {
  DarkSurfaceVariant.oled: Color(0xFF000000),
  DarkSurfaceVariant.darkGray: Color(0xFF1E1E1E),
  DarkSurfaceVariant.warmDark: Color(0xFF1A1512),
  DarkSurfaceVariant.coolDark: Color(0xFF101820),
};

const _darkSurfaceLabels = {
  DarkSurfaceVariant.standard: '標準',
  DarkSurfaceVariant.oled: 'OLED ブラック',
  DarkSurfaceVariant.darkGray: 'ダークグレー',
  DarkSurfaceVariant.warmDark: 'ウォームダーク',
  DarkSurfaceVariant.coolDark: 'クールダーク',
};

/// Human-readable label for a [DarkSurfaceVariant].
String darkSurfaceLabel(DarkSurfaceVariant v) => _darkSurfaceLabels[v] ?? '';

/// Resolve the surface [Color] for a variant, or null for standard.
Color? darkSurfaceColor(DarkSurfaceVariant v) => _darkSurfaceColors[v];

/// Provides the dark mode surface variant preference.
final darkSurfaceVariantProvider =
    NotifierProvider<DarkSurfaceVariantNotifier, DarkSurfaceVariant>(
      DarkSurfaceVariantNotifier.new,
    );

class DarkSurfaceVariantNotifier extends Notifier<DarkSurfaceVariant> {
  @override
  DarkSurfaceVariant build() {
    _load();
    return DarkSurfaceVariant.standard;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_darkSurfaceVariantKey);
    if (saved != null) {
      final v = DarkSurfaceVariant.values
          .where((e) => e.name == saved)
          .firstOrNull;
      if (v != null) state = v;
    }
  }

  Future<void> setVariant(DarkSurfaceVariant variant) async {
    state = variant;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_darkSurfaceVariantKey, variant.name);
  }
}

// --- Dark text color ---

/// Preset text colors for dark mode.
enum DarkTextColor {
  /// Default (Material 3 generated).
  standard,

  /// Pure white.
  white,

  /// Warm white (slightly yellowish).
  warmWhite,

  /// Cool white (slightly bluish).
  coolWhite,

  /// Light gray (reduced brightness).
  lightGray,
}

const _darkTextColors = {
  DarkTextColor.white: Color(0xFFFFFFFF),
  DarkTextColor.warmWhite: Color(0xFFF5F0E8),
  DarkTextColor.coolWhite: Color(0xFFE8EEF5),
  DarkTextColor.lightGray: Color(0xFFCCCCCC),
};

const _darkTextColorLabels = {
  DarkTextColor.standard: '標準',
  DarkTextColor.white: 'ホワイト',
  DarkTextColor.warmWhite: 'ウォームホワイト',
  DarkTextColor.coolWhite: 'クールホワイト',
  DarkTextColor.lightGray: 'ライトグレー',
};

/// Human-readable label for a [DarkTextColor].
String darkTextColorLabel(DarkTextColor v) => _darkTextColorLabels[v] ?? '';

/// Resolve the text [Color] for a variant, or null for standard.
Color? darkTextColor(DarkTextColor v) => _darkTextColors[v];

const _darkTextColorKey = 'dark_text_color';

/// Provides the dark mode text color preference.
final darkTextColorProvider =
    NotifierProvider<DarkTextColorNotifier, DarkTextColor>(
      DarkTextColorNotifier.new,
    );

class DarkTextColorNotifier extends Notifier<DarkTextColor> {
  @override
  DarkTextColor build() {
    _load();
    return DarkTextColor.standard;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_darkTextColorKey);
    if (saved != null) {
      final v = DarkTextColor.values.where((e) => e.name == saved).firstOrNull;
      if (v != null) state = v;
    }
  }

  Future<void> setColor(DarkTextColor color) async {
    state = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_darkTextColorKey, color.name);
  }
}
