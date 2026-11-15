import 'dart:async';
import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Annict の感想・記録の下書き (#1382)。
///
/// [ratings] は軸の名前（`overall` / `animation` / `music` / `story` /
/// `character`、record は `rating`）→ 評価。
class AnnictDraft {
  final String body;
  final Map<String, AnnictRatingState> ratings;

  const AnnictDraft({this.body = '', this.ratings = const {}});

  bool get isEmpty => body.trim().isEmpty && ratings.isEmpty;

  Map<String, dynamic> toJson() => {
    'body': body,
    'ratings': {for (final e in ratings.entries) e.key: e.value.name},
  };

  static AnnictDraft? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['ratings'];
    final ratings = <String, AnnictRatingState>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final state = AnnictRatingState.values
            .where((s) => s.name == e.value)
            .firstOrNull;
        if (e.key is String && state != null) ratings[e.key as String] = state;
      }
    }
    return AnnictDraft(body: json['body'] as String? ?? '', ratings: ratings);
  }
}

/// 下書きの種類。⚠ キーに入るので名前を変えない。
enum AnnictDraftKind {
  /// 作品全体の感想（`annict_review_screen.dart`）。作品 ID ごと。
  review,

  /// 話数ごとの記録（`annict_record_screen.dart`）。エピソード ID ごと。
  record,
}

/// Annict の感想・記録の下書きを、アカウント別・作品 / 話数別に保存する (#1382)。
///
/// 投稿フォームの `ComposeDraftStore` とは別にした。あちらは添付・公開範囲・
/// 世代印（複数の画面が 1 枠を取り合う）まで抱えるが、この画面は本文と評価だけで、
/// 枠も作品・話数ごとに分かれるので取り合いが起きない。⚠ 引き継いだ守りは 2 つ:
///
/// - **書き込みを直列にする**（[save] と [clear] が重なって、消したはずの下書きが
///   戻らないように）。⚠ [clear] のあとの [save] は書かない（投稿に成功して閉じる
///   途中の保存で、下書きが生き返らないように）
/// - 空の下書きは**キーごと消す**（作品・話数の数だけ溜まらないように）
class AnnictDraftStore {
  AnnictDraftStore({
    required this.accountKey,
    required this.kind,
    required this.id,
  });

  /// `AccountKey.toStorageKey()`。
  final String accountKey;
  final AnnictDraftKind kind;

  /// 作品 ID（review）/ エピソード ID（record）。
  final int id;

  static const prefix = 'annict_draft:';

  String get key => keyFor(accountKey, kind, id);

  static String keyFor(String accountKey, AnnictDraftKind kind, int id) =>
      '$prefix$accountKey:${kind.name}:$id';

  Future<void> _chain = Future.value();
  bool _cleared = false;

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _chain.then((_) => op());
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<AnnictDraft?> load() => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final draft = AnnictDraft.fromJson(jsonDecode(raw));
      return (draft == null || draft.isEmpty) ? null : draft;
    } catch (_) {
      return null;
    }
  });

  Future<void> save(AnnictDraft draft) => _serial(() async {
    if (_cleared) return;
    final prefs = await SharedPreferences.getInstance();
    if (draft.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(draft.toJson()));
    }
  });

  /// 投稿に成功したら呼ぶ。⚠ 以後このインスタンスの [save] は書かない。
  Future<void> clear() {
    _cleared = true;
    return _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    });
  }

  /// アカウントを消したときに、そのアカウントの下書きを全部消す。
  static Future<void> clearForAccount(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    final head = '$prefix$accountKey:';
    for (final k in prefs.getKeys().where((k) => k.startsWith(head)).toList()) {
      await prefs.remove(k);
    }
  }
}
