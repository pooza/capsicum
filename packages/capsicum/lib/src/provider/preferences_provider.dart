import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User preference keys.
const _fontScaleKey = 'font_scale';
const _themeColorPrefix = 'theme_color_';
const _tabOrderPrefix = 'tab_order_';

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
final fontScaleProvider =
    NotifierProvider<FontScaleNotifier, double>(FontScaleNotifier.new);

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
            (name) => TimelineType.values
                .where((t) => t.name == name)
                .firstOrNull,
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
