import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User preference keys.
const _fontScaleKey = 'font_scale';
const _themeColorPrefix = 'theme_color_';
const _tabOrderPrefix = 'tab_order_';
const _lastTabPrefix = 'last_tab_';
const _emojiPalettePrefix = 'emoji_palette_';
const _pinnedHashtagsPrefix = 'pinned_hashtags_';
const _hideLivecureKey = 'hide_livecure';
const _themeModeKey = 'theme_mode';
const _absoluteTimeKey = 'absolute_time';
const _blurAllImagesKey = 'blur_all_images';
const _confirmBeforePostKey = 'confirm_before_post';
const _previewCardModeKey = 'preview_card_mode';

/// Display mode for OGP preview cards.
enum PreviewCardMode {
  /// Show preview cards normally.
  show,

  /// Blur the preview card image.
  blur,

  /// Hide preview cards entirely.
  hide,
}

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
  @override
  String? build(String arg) {
    _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('$_lastTabPrefix$arg');
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> save(String value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_lastTabPrefix$arg', value);
  }
}

/// Default tab order for timelines.
const defaultTabOrder = [
  TimelineType.home,
  TimelineType.local,
  TimelineType.social,
  TimelineType.federated,
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

/// Per-host emoji palette (imported from Misskey Web UI).
///
/// Takes a hostname as the family parameter.
/// Returns an empty list when no palette has been imported.
final emojiPaletteProvider =
    NotifierProvider.family<EmojiPaletteNotifier, List<String>, String>(
      EmojiPaletteNotifier.new,
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
      final mode =
          PreviewCardMode.values.where((m) => m.name == saved).firstOrNull;
      if (mode != null) state = mode;
    }
  }

  Future<void> setMode(PreviewCardMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_previewCardModeKey, mode.name);
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
