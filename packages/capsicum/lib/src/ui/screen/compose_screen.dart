import 'dart:io';

import 'dart:async';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../provider/account_manager_provider.dart';
import '../widget/content_parser.dart';
import '../../provider/channel_provider.dart';
import '../../provider/instance_provider.dart';
import '../../provider/platform_providers.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';
import '../util/livecure_snackbar.dart';
import '../util/post_scope_display.dart';
import '../util/shortcode_warning_controller.dart';
import '../util/user_acct.dart';
import '../widget/emoji_picker.dart';
import '../widget/emoji_text.dart';
import 'annict_record_screen.dart';
import 'drive_picker_screen.dart';
import 'image_crop_screen.dart';

class _MediaEntry {
  // トリミング (#577) で差し替えるため可変。drive ファイルは差し替えない。
  XFile? file;
  final Attachment? driveFile;
  String description = '';
  bool sensitive = false;

  _MediaEntry.local(XFile this.file) : driveFile = null;

  _MediaEntry.drive(Attachment this.driveFile)
    : file = null,
      description = driveFile.description ?? '',
      sensitive = false;

  bool get isDrive => driveFile != null;
}

/// 添付サイズ超過で reject したファイルの集約用 (#375)。
class _OversizeFile {
  final String name;
  final int size;
  final int limit;

  const _OversizeFile({
    required this.name,
    required this.size,
    required this.limit,
  });
}

/// 語字 (Unicode の Letter / Number / アンダースコア)。トリガ直前がこれ以外
/// なら「語の先頭」とみなす。
final RegExp _composeWordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

/// カーソル位置から後方へ走査し、補完トリガ ([trigger] = `@` / `#` / `:`) の
/// 直後クエリ文字列を返す。トリガ語でなければ null。
///
/// トリガが発火するのは「文頭」または「直前文字が語字でない」場合のみ。
/// 旧実装は半角空白 / 改行 / 文頭のみを境界としていたため、日本語の
/// 「。@user」「）#tag」全角空白・タブ等の直後で不発だった (#581 観点1)。
/// 語字を除外する形なので `foo@bar`(メール) や `12:34`(時刻) を誤発火しない
/// 旧来の意図は維持される。State から切り出した純粋関数 (テスト対象)。
String? composeTriggerQuery({
  required String text,
  required int cursor,
  required String trigger,
}) {
  if (cursor < 0 || cursor > text.length) return null;
  var start = cursor - 1;
  while (start >= 0) {
    final ch = text[start];
    if (ch == trigger) {
      if (start == 0 || !_composeWordChar.hasMatch(text[start - 1])) {
        final query = text.substring(start + 1, cursor);
        return query.isNotEmpty ? query : null;
      }
      return null;
    }
    // クエリ内に空白系が現れたらトリガ語ではない。半角/全角空白・改行・
    // タブ・CR を区切りとして扱う (#581 観点1: 全角空白等への拡張)。
    if (ch == ' ' || ch == '　' || ch == '\n' || ch == '\r' || ch == '\t') {
      return null;
    }
    start--;
  }
  return null;
}

class ComposeScreen extends ConsumerStatefulWidget {
  final Post? redraft;
  final Post? replyTo;
  final Post? quoteTo;
  final String? channelId;
  final String? channelName;
  final String? sharedText;
  final String? initialText;

  const ComposeScreen({
    super.key,
    this.redraft,
    this.replyTo,
    this.quoteTo,
    this.channelId,
    this.channelName,
    this.sharedText,
    this.initialText,
  });

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

/// SharedPreferences keys for the auto-saved compose draft.
///
/// Only fresh compose sessions (no reply/quote/redraft/shared/initial text)
/// participate in auto-save, so a single global slot is sufficient.
const _draftTextKey = 'compose_draft_text';
const _draftCwTextKey = 'compose_draft_cw_text';
const _draftCwEnabledKey = 'compose_draft_cw_enabled';

class _ComposeScreenState extends ConsumerState<ComposeScreen>
    with WidgetsBindingObserver {
  final _controller = ShortcodeWarningController();
  final _cwController = TextEditingController();
  final List<_MediaEntry> _attachments = [];
  // OS のファイラーからのドラッグ中だけ true。ドロップ可能なことを示す
  // ハイライト表示に使う (#571)。デスクトップ以外では発火しない。
  bool _dragging = false;
  PostScope _scope = PostScope.public;
  bool _cwEnabled = false;
  bool _sensitiveEnabled = false;
  bool _sending = false;
  bool _localOnly = false;
  DateTime? _scheduledAt;
  String? _language;
  List<User> _mentionSuggestions = [];
  List<String> _hashtagSuggestions = [];
  Timer? _mentionDebounce;

  // サジェスト取得の世代カウンタ (#581 観点2)。debounce 後に走るサーバー検索は
  // in-flight キャンセルできないため、発火ごとに採番し await 解決時に最新世代
  // でなければ後着レスポンスを破棄する。古いクエリの結果が新しい候補を上書き
  // する race を防ぐ。絵文字はローカル絞り込みのため対象外。
  int _mentionFetchGen = 0;
  int _hashtagFetchGen = 0;

  // インライン絵文字補完 (#308)。デスクトップ実況用途で「キーボードから手を
  // 離さずカスタム絵文字を入れる」ことを主目的にする。サーバー側で
  // CustomEmojiSupport を実装しているアダプタのみ対象。
  List<CustomEmoji> _emojiSuggestions = [];
  List<CustomEmoji>? _allEmojis;

  // Quote approval policy (Mastodon 4.5+)
  String? _quoteApprovalPolicy;

  /// Whether this compose session participates in draft auto-save.
  ///
  /// True only for fresh compose sessions (no reply/quote/redraft/shared/
  /// initial text). Replies and quotes are tied to a specific post and
  /// can't be meaningfully restored from a text-only draft.
  bool _draftAutoSave = false;

  /// Misskey は親投稿のチャンネルにぶら下げるのが Web UI 期待挙動。呼び出し側
  /// (post_tile / notification_tile) は replyTo / redraft / quoteTo だけ
  /// 渡してくるので、ここでフォールバックして全経路で継承する
  /// (#378 / #384 / #401)。
  String? get _effectiveChannelId =>
      widget.channelId ??
      widget.redraft?.channelId ??
      widget.replyTo?.channelId ??
      widget.quoteTo?.channelId;
  String? get _effectiveChannelName =>
      widget.channelName ??
      widget.redraft?.channelName ??
      widget.replyTo?.channelName ??
      widget.quoteTo?.channelName;

  // Poll state
  bool _pollEnabled = false;
  final List<TextEditingController> _pollControllers = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _pollMultiple = false;
  int _pollExpiresIn = 86400; // 1 day in seconds

  static const _quoteApprovalLabels = {
    'public': '誰でも',
    'followers': 'フォロワーのみ',
    'nobody': '許可しない',
  };

  static const _quoteApprovalIcons = {
    'public': Icons.public,
    'followers': Icons.lock_outline,
    'nobody': Icons.block,
  };

  static const _languageOptions = {
    'ja': '日本語',
    'en': 'English',
    'zh': '中文',
    'ko': '한국어',
    'fr': 'Français',
    'de': 'Deutsch',
    'es': 'Español',
    'pt': 'Português',
    'ru': 'Русский',
  };

  List<DropdownMenuItem<PostScope>> _scopeItems(WidgetRef ref) {
    final adapter = ref.read(currentAdapterProvider);
    return PostScope.values.map((scope) {
      final display = postScopeDisplay(scope, adapter);
      return DropdownMenuItem(
        value: scope,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(display.icon, size: 16),
            const SizedBox(width: 4),
            Text(display.label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    final redraft = widget.redraft;
    final replyTo = widget.replyTo;
    if (redraft != null) {
      _controller.text = _extractPlainText(redraft.content ?? '');
      _scope = redraft.scope;
    } else if (replyTo != null) {
      _scope = replyTo.scope;
      _initReplyMentions(replyTo);
    } else if (widget.quoteTo != null) {
      _scope = widget.quoteTo!.scope;
    } else if (widget.sharedText != null) {
      _controller.text = '#nowplaying ${widget.sharedText!}\n';
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
      final account = ref.read(currentAccountProvider);
      if (account != null && account.user.defaultScope != null) {
        _scope = account.user.defaultScope!;
      }
    } else if (widget.initialText != null) {
      _controller.text = widget.initialText!;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
      final account = ref.read(currentAccountProvider);
      if (account != null && account.user.defaultScope != null) {
        _scope = account.user.defaultScope!;
      }
    } else {
      final account = ref.read(currentAccountProvider);
      if (account != null && account.user.defaultScope != null) {
        _scope = account.user.defaultScope!;
      }
      // Fresh compose: enable draft auto-save and try to restore the
      // previously saved draft (if any).
      _draftAutoSave = true;
      _restoreDraft();
    }
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onTextChanged);
    // Mastodon のみ: デフォルト言語をロケールから設定
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final adapter = ref.read(currentAdapterProvider);
      if (adapter is MastodonAdapter) {
        setState(
          () => _language = Localizations.localeOf(context).languageCode,
        );
      }
      // CustomEmojiSupport 対応サーバーなら絵文字を先読み (#308)。
      // 補完候補のフィルタはローカルで行うため、起動時に 1 回ロードして
      // 以降は in-memory で絞り込む。Fire-and-forget で UI を待たせない。
      if (adapter is CustomEmojiSupport) {
        _loadAllEmojis(adapter as CustomEmojiSupport);
      }
    });
  }

  Future<void> _loadAllEmojis(CustomEmojiSupport support) async {
    try {
      final emojis = await support.getEmojis();
      if (mounted) {
        setState(() => _allEmojis = emojis);
        // 既に入力済みの shortcode に警告を当て直す (#609)。
        _updateShortcodeWarnings();
      }
    } catch (e) {
      // 失敗しても投稿フォーム自体は使えるので breadcrumb のみ残す。
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'compose.emoji.preload',
          message: e.runtimeType.toString(),
          level: SentryLevel.warning,
        ),
      );
    }
  }

  /// Walk backwards from cursor to find [trigger] (`@` or `#`).
  /// Returns the query string after the trigger, or null.
  String? _currentTriggerQuery(String trigger) => composeTriggerQuery(
    text: _controller.text,
    cursor: _controller.selection.baseOffset,
    trigger: trigger,
  );

  void _onTextChanged() {
    // 既存の debounce は IME 中でも止める (#511): early return より前に
    // cancel しないと、IME 確定前の前回 query が 300ms 後に発火して古い
    // 候補を出してしまう race が残る。
    _mentionDebounce?.cancel();

    // IME 変換中は setState を抑制（rebuild が EditableText の composition / selection を
    // 巻き戻す Flutter 上流症例の触媒になるため。#463 / #54 同型）
    if (_controller.value.composing.isValid) return;

    // 入力中に未登録 shortcode を赤波下線で警告 (#609)。Mastodon 限定。
    _updateShortcodeWarnings();

    // Check mention trigger first, then hashtag, then emoji (#308)。
    final mentionQuery = _currentTriggerQuery('@');
    final hashtagQuery = mentionQuery == null
        ? _currentTriggerQuery('#')
        : null;
    final emojiQuery = (mentionQuery == null && hashtagQuery == null)
        ? _currentEmojiTriggerQuery()
        : null;

    if (mentionQuery == null && _mentionSuggestions.isNotEmpty) {
      setState(() => _mentionSuggestions = []);
    }
    if (hashtagQuery == null && _hashtagSuggestions.isNotEmpty) {
      setState(() => _hashtagSuggestions = []);
    }
    if (emojiQuery == null && _emojiSuggestions.isNotEmpty) {
      setState(() => _emojiSuggestions = []);
    }

    if (mentionQuery != null) {
      _mentionDebounce = Timer(const Duration(milliseconds: 300), () {
        _fetchMentionSuggestions(mentionQuery);
      });
    } else if (hashtagQuery != null) {
      _mentionDebounce = Timer(const Duration(milliseconds: 300), () {
        _fetchHashtagSuggestions(hashtagQuery);
      });
    } else if (emojiQuery != null) {
      // 絵文字はローカル絞り込みのため debounce 不要 (即時反映)。
      _updateEmojiSuggestions(emojiQuery);
    }
  }

  /// 自サーバー custom_emojis に未登録の shortcode 集合を controller に渡し、
  /// 赤波下線装飾を更新する (#609)。adapter が Mastodon でない、または絵文字
  /// 一覧がまだ読み込まれていない場合は警告を出さない (false positive 回避)。
  void _updateShortcodeWarnings() {
    final adapter = ref.read(currentAdapterProvider);
    final allEmojis = _allEmojis;
    if (adapter is! MastodonAdapter || allEmojis == null) {
      _controller.setUnknownShortcodes(const {});
      return;
    }
    final known = {for (final e in allEmojis) e.shortcode};
    final unknown = <String>{};
    for (final match in shortcodePattern.allMatches(_controller.text)) {
      final code = match.group(1)!;
      if (!known.contains(code)) unknown.add(code);
    }
    _controller.setUnknownShortcodes(unknown);
  }

  /// `:shortcode` 形式の補完トリガを検出する (#308)。
  /// `_currentTriggerQuery(':')` をそのまま使うと `12:34` のような時刻表記も
  /// 拾い得るが、`:` の前が語字 (英数字 / アンダースコア) でないことを要求する
  /// _currentTriggerQuery の境界条件で正しく除外できる (`12:` は直前が数字)。
  /// ただし `:smi:` のようにクエリ後ろに閉じコロンが続く完成形は補完不要なので
  /// この場合は null を返す。
  String? _currentEmojiTriggerQuery() {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) return null;
    // 直後の文字が `:` (完成形 `:smi:` 等) なら補完不要。
    if (cursor < text.length && text[cursor] == ':') return null;
    final query = _currentTriggerQuery(':');
    if (query == null) return null;
    // 候補絞り込み用にショートコードに使われる文字 (英数字 / アンダースコア /
    // ハイフン / プラス) のみ許容。空白以外の記号で始まる「:" や ":@" のような
    // 入力は補完対象外。
    final valid = RegExp(r'^[a-zA-Z0-9_\-+]+$');
    if (!valid.hasMatch(query)) return null;
    return query;
  }

  Future<void> _fetchMentionSuggestions(String query) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! SearchSupport) return;
    final gen = ++_mentionFetchGen;
    try {
      final users = await (adapter as SearchSupport).searchUsers(
        query,
        limit: 5,
      );
      // 後着レスポンス破棄 (#581 観点2): await 中に新しい入力で再発火して
      // いたら世代が進んでいる。古い結果で新しい候補を上書きしない。
      if (gen != _mentionFetchGen) return;
      if (mounted) setState(() => _mentionSuggestions = users);
    } catch (e) {
      // best-effort なサジェスト系。致命でないので breadcrumb のみ残し、
      // サーバー側 schema 変更や rate-limit を「サジェスト出ない」だけで
      // 取りこぼさないようにする (#553)。
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'compose.search.users',
          message: e.runtimeType.toString(),
          level: SentryLevel.warning,
        ),
      );
    }
  }

  Future<void> _fetchHashtagSuggestions(String query) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! SearchSupport) return;
    final gen = ++_hashtagFetchGen;
    try {
      final tags = await (adapter as SearchSupport).searchHashtags(
        query,
        limit: 5,
      );
      if (gen != _hashtagFetchGen) return;
      if (mounted) setState(() => _hashtagSuggestions = tags);
    } catch (e) {
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'compose.search.hashtags',
          message: e.runtimeType.toString(),
          level: SentryLevel.warning,
        ),
      );
    }
  }

  void _insertMention(User user) {
    final acct = _buildAcct(user);
    _insertTriggerCompletion('@', '@$acct ');
    setState(() => _mentionSuggestions = []);
  }

  void _insertHashtag(String tag) {
    _insertTriggerCompletion('#', '#$tag ');
    setState(() => _hashtagSuggestions = []);
  }

  void _updateEmojiSuggestions(String query) {
    final all = _allEmojis;
    if (all == null || all.isEmpty) return;
    final lower = query.toLowerCase();
    // 先頭一致を優先し、その後に部分一致 / alias 一致を続ける。Mastodon /
    // Misskey Web UI と同様の挙動。最大 20 件で打ち切り、横スクロール chips
    // のレイアウト崩れを防ぐ。
    // 補完は picker と同じく visible_in_picker=false を除外する (#622)。
    // 警告判定用に `_allEmojis` 自体は全件保持しているため、ここでフィルタする。
    final prefix = <CustomEmoji>[];
    final contain = <CustomEmoji>[];
    for (final e in all) {
      if (!e.visibleInPicker) continue;
      final sc = e.shortcode.toLowerCase();
      if (sc.startsWith(lower)) {
        prefix.add(e);
      } else if (sc.contains(lower) ||
          e.aliases.any((a) => a.toLowerCase().contains(lower))) {
        contain.add(e);
      }
      if (prefix.length >= 20) break;
    }
    final merged = [...prefix, ...contain].take(20).toList();
    setState(() => _emojiSuggestions = merged);
  }

  void _completeEmojiFromSuggestion(CustomEmoji emoji) {
    // 部分入力 `:query` を一旦削除してから既存の _insertEmoji を呼ぶ。
    // 既存ロジックが Mastodon の前後スペース / zwsp / カーソル位置を統一して
    // 面倒見ているので、EmojiPicker からの挿入と完全に同じ挙動になる。
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    var start = cursor - 1;
    while (start >= 0 && text[start] != ':') {
      start--;
    }
    if (start < 0) return;
    _controller.value = TextEditingValue(
      text: text.replaceRange(start, cursor, ''),
      selection: TextSelection.collapsed(offset: start),
    );
    _insertEmoji(':${emoji.shortcode}:');
    setState(() => _emojiSuggestions = []);
  }

  void _insertTriggerCompletion(String trigger, String replacement) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    var start = cursor - 1;
    while (start >= 0 && text[start] != trigger) {
      start--;
    }
    final newText = text.replaceRange(start, cursor, replacement);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mentionDebounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _cwController.dispose();
    for (final c in _pollControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // ソフトキーボード開閉 (metrics 変化) で「しまう」ボタンの出し分けを
    // 反映するため rebuild する (#594 / #635)。View.of(context).viewInsets を
    // 見る判定がキーボード開閉に追従するように。addObserver は initState で
    // 登録済み。
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // The OS may dispose the activity while backgrounded; persist the draft
    // on every transition out of `resumed` so it survives a cold restart.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _saveDraft();
    }
  }

  /// Persist the current draft text and CW state to SharedPreferences.
  ///
  /// No-op for reply / quote / redraft / shared / initial-text sessions.
  Future<void> _saveDraft() async {
    if (!_draftAutoSave) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftTextKey, _controller.text);
    await prefs.setString(_draftCwTextKey, _cwController.text);
    await prefs.setBool(_draftCwEnabledKey, _cwEnabled);
  }

  /// Restore a previously saved draft into the controllers.
  Future<void> _restoreDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final savedText = prefs.getString(_draftTextKey);
    final savedCwText = prefs.getString(_draftCwTextKey);
    final savedCwEnabled = prefs.getBool(_draftCwEnabledKey) ?? false;
    if (!mounted) return;
    if (savedText != null && savedText.isNotEmpty) {
      _controller.text = savedText;
      _controller.selection = TextSelection.collapsed(offset: savedText.length);
    }
    if (savedCwText != null && savedCwText.isNotEmpty) {
      _cwController.text = savedCwText;
    }
    if (savedCwEnabled) {
      setState(() => _cwEnabled = true);
    }
  }

  /// Remove any persisted draft (called after a successful post).
  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftTextKey);
    await prefs.remove(_draftCwTextKey);
    await prefs.remove(_draftCwEnabledKey);
  }

  void _initReplyMentions(Post replyTo) {
    final currentUser = ref.read(currentAccountProvider)?.user;
    final mentions = <String>{};

    // Add the author of the post being replied to.
    final authorAcct = _buildAcct(replyTo.author);
    if (currentUser == null || replyTo.author.id != currentUser.id) {
      mentions.add(authorAcct);
    }

    if (mentions.isNotEmpty) {
      final prefix = mentions.map((m) => '@$m').join(' ');
      _controller.text = '$prefix ';
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  String _buildAcct(User user) => userAcct(user);

  String _extractPlainText(String content) {
    final isHtml = content.contains('<') && content.contains('>');
    if (!isHtml) return content;
    return stripHtml(content);
  }

  void _insertEmoji(String emoji) {
    final text = _controller.text;
    final sel = _controller.selection;
    final start = sel.baseOffset < 0 ? text.length : sel.baseOffset;
    final end = sel.extentOffset < 0 ? text.length : sel.extentOffset;

    // Mastodon ではカスタム絵文字の前後にスペースが必要（Misskey は不要）。
    final isMastodon =
        ref.read(currentAccountProvider)?.adapter is! ReactionSupport;
    final isCustom = emoji.startsWith(':') && emoji.endsWith(':');
    final needsSpace = isCustom && isMastodon;
    final useZwsp = ref.read(emojiZeroWidthSpaceProvider);
    final sep = useZwsp ? '\u200B' : ' ';
    final prefix = needsSpace && start > 0 && text[start - 1] != sep ? sep : '';
    final suffix = needsSpace && end < text.length && text[end] != sep
        ? sep
        : '';
    final insertion = '$prefix$emoji$suffix';

    final newText = text.replaceRange(start, end, insertion);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + insertion.length),
    );
  }

  void _showEmojiPicker() {
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    if (adapter == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.5,
        child: EmojiPicker(
          adapter: adapter as BackendAdapter,
          host: account!.key.host,
          mulukhiya: account.mulukhiya,
          accessToken: account.userSecret.accessToken,
          onSelected: (emoji) {
            _insertEmoji(emoji);
          },
        ),
      ),
    );
  }

  Future<void> _pickMedia() async {
    final files = await ref.read(mediaPickerProvider).pickMultipleMedia();
    await _addLocalMedia(files);
  }

  /// ピッカー / ドラッグ&ドロップ共通のローカルメディア追加経路。
  ///
  /// サーバーが上限を返している場合のみ事前にサイズ比較し、超過分は除外して
  /// ダイアログで知らせる。未取得 / fetch 失敗時はチェックを丸ごとスキップし、
  /// 従来どおりサーバーエラーで知る経路に任せる
  /// (#375、CLAUDE.md「機能不足時の通知」)。
  Future<void> _addLocalMedia(List<XFile> files) async {
    if (files.isEmpty) return;

    final instance = await ref.read(currentInstanceProvider.future);

    final accepted = <XFile>[];
    final rejected = <_OversizeFile>[];
    for (final f in files) {
      final type = _attachmentTypeFor(f);
      final limit = instance?.maxAttachmentSizeBytes(type);
      if (limit != null) {
        final size = await f.length();
        if (size > limit) {
          rejected.add(_OversizeFile(name: f.name, size: size, limit: limit));
          continue;
        }
      }
      accepted.add(f);
    }

    if (accepted.isNotEmpty && mounted) {
      setState(() {
        _attachments.addAll(accepted.map((f) => _MediaEntry.local(f)));
      });
    }
    if (rejected.isNotEmpty && mounted) {
      await _showOversizeDialog(rejected);
    }
  }

  /// OS のファイラーからドロップされたファイルのうち、メディア (画像 / 動画 /
  /// 音声) だけを添付する。それ以外は無視し、すべて対象外なら軽く通知する。
  /// デスクトップ (macOS / Windows / Linux) でのみ発火する (#571)。
  Future<void> _onDragDone(DropDoneDetails detail) async {
    if (_sending) return;
    final media = detail.files.where(_isDroppableMedia).toList();
    if (media.isNotEmpty) {
      await _addLocalMedia(media);
    } else if (detail.files.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('メディアファイル (画像 / 動画 / 音声) のみ添付できます')),
      );
    }
  }

  bool _isDroppableMedia(XFile file) {
    final mime = file.mimeType;
    if (mime != null && mime.isNotEmpty) {
      return mime.startsWith('image/') ||
          mime.startsWith('video/') ||
          mime.startsWith('audio/');
    }
    final ext = file.path.toLowerCase().split('.').last;
    return _imageExtensions.contains(ext) ||
        _videoExtensions.contains(ext) ||
        _audioExtensions.contains(ext);
  }

  AttachmentType _attachmentTypeFor(XFile file) {
    final mime = file.mimeType;
    if (mime != null) {
      if (mime.startsWith('image/')) return AttachmentType.image;
      if (mime.startsWith('video/')) return AttachmentType.video;
      if (mime.startsWith('audio/')) return AttachmentType.audio;
    }
    if (_isVideo(mime, file.path)) return AttachmentType.video;
    // MIME 不明の path ベースドロップ (#653) は拡張子で audio を判定する。
    // ここで拾い損ねると .mp3 / .flac 等が下の image 扱いに落ち、
    // image_size_limit と比較され、サムネも Image.file で音声を画像描画
    // しようとする。
    if (_isAudio(mime, file.path)) return AttachmentType.audio;
    // pickMultipleMedia の戻り値は image / video のいずれかなので、ここに
    // 落ちるのは MIME 不明の画像が大半。image を仮定して image_size_limit と
    // 比較する。
    return AttachmentType.image;
  }

  Future<void> _showOversizeDialog(List<_OversizeFile> files) async {
    String formatMb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
    final body = files.length == 1
        ? 'このサーバーでは最大 ${formatMb(files.first.limit)} MB までです\n'
              'このファイル: ${formatMb(files.first.size)} MB'
        : files
              .map(
                (f) =>
                    '・${f.name}\n  ${formatMb(f.size)} MB '
                    '(上限 ${formatMb(f.limit)} MB)',
              )
              .join('\n');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ファイルサイズ上限を超えています'),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDriveFiles() async {
    final selected = await Navigator.of(context).push<List<Attachment>>(
      MaterialPageRoute(builder: (_) => const DrivePickerScreen()),
    );
    if (selected != null && selected.isNotEmpty) {
      setState(() {
        _attachments.addAll(selected.map((f) => _MediaEntry.drive(f)));
      });
    }
  }

  void _removeAttachment(int index) {
    setState(() => _attachments.removeAt(index));
  }

  /// 画像トリミングを提供するのはデスクトップ (macOS / Windows / Linux) のみ。
  /// モバイルのトリミング (#568) は image_picker ベースの別経路で対応する想定の
  /// ため、ここでは導線を出さない (#577)。
  static final bool _supportsCrop =
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// トリミング対象にできるのはローカルの静止画のみ。動画 / 音声 / ドライブ
  /// ファイルは対象外。GIF はアニメーションが失われるため除外する。
  bool _isCroppableImage(_MediaEntry entry) {
    if (entry.isDrive || entry.file == null) return false;
    final file = entry.file!;
    final mime = file.mimeType;
    if (mime != null && mime.isNotEmpty) {
      return mime.startsWith('image/') && mime != 'image/gif';
    }
    final ext = file.path.toLowerCase().split('.').last;
    return _imageExtensions.contains(ext) && ext != 'gif';
  }

  /// 添付済みのローカル画像をトリミングし、結果で元の添付を差し替える (#577)。
  /// 説明 (ALT) と閲覧注意フラグは引き継ぐ。トリミング結果は一時ディレクトリに
  /// 書き出し、元のフォーマット (拡張子) と MIME タイプを維持する。
  Future<void> _cropImage(int index) async {
    final entry = _attachments[index];
    final original = entry.file;
    if (original == null) return;

    final Uint8List bytes;
    try {
      bytes = await original.readAsBytes();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('画像を読み込めませんでした')));
      }
      return;
    }
    if (!mounted) return;

    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => ImageCropScreen(imageData: bytes),
        fullscreenDialog: true,
      ),
    );
    if (cropped == null || !mounted) return;

    final XFile croppedFile;
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      // トリミング結果は常に PNG で返るため、拡張子・MIME を PNG に揃える。
      // 元が WebP/HEIC 等でもサーバー (モロヘイヤ) 側で再変換されるので問題ない。
      final baseName = original.name.isNotEmpty ? original.name : 'image';
      final dotIndex = baseName.lastIndexOf('.');
      final stem = dotIndex > 0 ? baseName.substring(0, dotIndex) : baseName;
      final pngName = '$stem.png';
      final path = '${dir.path}/crop_${stamp}_$pngName';
      final out = File(path);
      // macOS の一時ディレクトリは実体が未作成のことがあり、writeAsBytes は
      // 親ディレクトリを作らないため明示的に作成する。
      await out.create(recursive: true);
      await out.writeAsBytes(cropped, flush: true);
      croppedFile = XFile(path, mimeType: 'image/png', name: pngName);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('トリミング結果を保存できませんでした')));
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      // 差し替え後も同じ添付スロットを保つため index を再取得せず置換する。
      entry.file = croppedFile;
    });
  }

  static const _videoExtensions = {
    'mov',
    'mp4',
    'avi',
    'mkv',
    'webm',
    'm4v',
    '3gp',
  };

  // ドラッグ&ドロップで添付可能なメディア判定用 (#571)。ファイラー由来の
  // XFile は mimeType が null のことが多いため拡張子でも判定する。
  static const _imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'avif',
    'tiff',
  };

  static const _audioExtensions = {
    'mp3',
    'm4a',
    'aac',
    'wav',
    'flac',
    'ogg',
    'oga',
    'opus',
  };

  bool _isVideo(String? mimeType, [String? path]) {
    if (mimeType != null && mimeType.startsWith('video/')) return true;
    if (path != null) {
      final ext = path.toLowerCase().split('.').last;
      return _videoExtensions.contains(ext);
    }
    return false;
  }

  bool _isAudio(String? mimeType, [String? path]) {
    if (mimeType != null && mimeType.startsWith('audio/')) return true;
    if (path != null) {
      final ext = path.toLowerCase().split('.').last;
      return _audioExtensions.contains(ext);
    }
    return false;
  }

  Widget _buildThumbnail(_MediaEntry entry) {
    const size = 100.0;
    if (entry.isDrive) {
      final df = entry.driveFile!;
      final preview = df.previewUrl ?? df.url;
      final isImage =
          df.type == AttachmentType.image || df.type == AttachmentType.gifv;
      if (isImage && preview.isNotEmpty) {
        return Image.network(
          preview,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            width: size,
            height: size,
            color: Colors.black87,
            child: const Center(
              child: Icon(Icons.broken_image, color: Colors.white),
            ),
          ),
        );
      }
      return Container(
        width: size,
        height: size,
        color: Colors.black87,
        child: Center(
          child: Icon(
            df.type == AttachmentType.video
                ? Icons.videocam
                : df.type == AttachmentType.audio
                ? Icons.audio_file
                : Icons.insert_drive_file,
            color: Colors.white,
            size: 36,
          ),
        ),
      );
    }
    // Local file
    final isVideo = _isVideo(entry.file!.mimeType, entry.file!.path);
    // MIME 不明で audio がここに落ちると Image.file で音声を画像描画して
    // しまう (#653)。video と同じくアイコン表示にフォールバックする。
    final isAudio =
        !isVideo && _isAudio(entry.file!.mimeType, entry.file!.path);
    if (isVideo || isAudio) {
      return Container(
        width: size,
        height: size,
        color: Colors.black87,
        child: Center(
          child: Icon(
            isVideo ? Icons.videocam : Icons.audio_file,
            color: Colors.white,
            size: 36,
          ),
        ),
      );
    }
    return Image.file(
      File(entry.file!.path),
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
  }

  static const _pollDurationOptions = <int, String>{
    300: '5分',
    1800: '30分',
    3600: '1時間',
    21600: '6時間',
    43200: '12時間',
    86400: '1日',
    259200: '3日',
    604800: '7日',
  };

  void _addPollOption() {
    if (_pollControllers.length >= 10) return;
    setState(() => _pollControllers.add(TextEditingController()));
  }

  void _removePollOption(int index) {
    if (_pollControllers.length <= 2) return;
    setState(() {
      _pollControllers[index].dispose();
      _pollControllers.removeAt(index);
    });
  }

  Widget _buildPollEditor() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _pollControllers.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pollControllers[i],
                      decoration: InputDecoration(
                        hintText: '選択肢 ${i + 1}',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  if (_pollControllers.length > 2)
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _sending ? null : () => _removePollOption(i),
                    ),
                ],
              ),
            ),
          Row(
            children: [
              if (_pollControllers.length < 10)
                TextButton.icon(
                  onPressed: _sending ? null : _addPollOption,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('選択肢を追加'),
                ),
              const Spacer(),
              FilterChip(
                label: const Text('複数選択'),
                selected: _pollMultiple,
                onSelected: _sending
                    ? null
                    : (v) => setState(() => _pollMultiple = v),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.timer_outlined, size: 16),
              const SizedBox(width: 4),
              DropdownButton<int>(
                value: _pollExpiresIn,
                underline: const SizedBox.shrink(),
                isDense: true,
                onChanged: _sending
                    ? null
                    : (v) {
                        if (v != null) setState(() => _pollExpiresIn = v);
                      },
                items: _pollDurationOptions.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editDescription(int index) async {
    final entry = _attachments[index];
    final descController = TextEditingController(text: entry.description);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('メディアの説明'),
        content: TextField(
          controller: descController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '画像の説明を入力（ALT テキスト）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, descController.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() => entry.description = result);
    }
  }

  Future<void> _openEpisodeBrowser() async {
    final result = await context.push<String>('/episodes');
    if (result != null && mounted) {
      _controller.text = result.replaceFirst(RegExp(r'^---\n'), '');
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  // 番組表エントリから直接 Annict 感想投稿画面に遷移する (#298)。
  // annict_episode_id が埋まっているエントリ (= 実在番組) のみ呼ばれる前提。
  void _openAnnictRecord(MulukhiyaProgram program) {
    final episodeId = program.annictEpisodeId;
    if (episodeId == null) return;
    final episodeLabel = [
      if (program.episode != null)
        '${program.episode}${program.episodeSuffix?.isNotEmpty == true ? program.episodeSuffix! : '話'}',
      if (program.subtitle != null) program.subtitle!,
    ].join(' ');
    context.push(
      '/annict/record',
      extra: AnnictRecordScreenArgs(
        episodeId: episodeId,
        workTitle: program.series ?? program.name,
        episodeLabel: episodeLabel,
      ),
    );
  }

  Future<void> _showTagsetSheet() async {
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    if (mulukhiya == null) return;

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return _TagsetSheet(
          mulukhiya: mulukhiya,
          annictEnabled: mulukhiya.annictEnabled,
          onSelect: (program) {
            Navigator.pop(sheetContext);
            _insertTagsetYaml(program);
          },
          onClear: () {
            Navigator.pop(sheetContext);
            _insertTagsetYaml(null);
            _restoreDecoration();
          },
          onEpisodeBrowser: () {
            Navigator.pop(sheetContext);
            _openEpisodeBrowser();
          },
          onAnnictRecord: (program) {
            Navigator.pop(sheetContext);
            _openAnnictRecord(program);
          },
          onReload: () async {
            try {
              await mulukhiya.updateProgram();
              if (sheetContext.mounted) {
                Navigator.pop(sheetContext);
              }
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('番組表を更新しました')));
              }
            } catch (e) {
              if (sheetContext.mounted) {
                Navigator.pop(sheetContext);
              }
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('更新に失敗しました')));
              }
            }
          },
        );
      },
    );
  }

  void _insertTagsetYaml(MulukhiyaProgram? program) {
    final String yaml;

    if (program == null) {
      yaml = 'command: user_config\ntagging:\n  user_tags: null';
    } else {
      final tags = <String>[];
      if (program.series != null) tags.add(program.series!);
      if (program.air) tags.add('エア番組');
      if (program.livecure) tags.add('実況');
      if (program.episode != null) {
        final suffix = (program.episodeSuffix?.isNotEmpty ?? false)
            ? program.episodeSuffix!
            : '話';
        tags.add('${program.episode}$suffix');
      }
      if (program.subtitle != null) tags.add(program.subtitle!);
      tags.addAll(program.extraTags);

      final yamlTags = tags.map((t) => '  - $t').join('\n');
      final lines = ['command: user_config', 'tagging:', '  user_tags:'];
      lines.add(yamlTags);
      if (program.minutes != null) {
        lines.add('  minutes: ${program.minutes}');
        lines.add('decoration:');
        lines.add('  minutes: ${program.minutes}');
      }
      yaml = lines.join('\n');
    }

    _controller.text = yaml;
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  Future<void> _restoreDecoration() async {
    final account = ref.read(currentAccountProvider);
    final mulukhiya = account?.mulukhiya;
    if (account == null || mulukhiya == null) return;
    try {
      await mulukhiya.restoreDecoration(account.userSecret.accessToken);
    } catch (e) {
      // best-effort。失敗してもユーザー操作には支障なし。
      // モロヘイヤ側の不調・API 変更を breadcrumb で観測可能にする (#553)。
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'compose.decoration.restore',
          message: e.runtimeType.toString(),
          level: SentryLevel.warning,
        ),
      );
    }
  }

  Future<void> _showPreview() async {
    final text = _controller.text;
    if (text.trim().isEmpty && !_pollEnabled) return;
    final account = ref.read(currentAccountProvider);
    final user = account?.user;
    if (user == null) return;

    final emojiSize = ref.read(emojiSizeProvider);
    final allEmojis = {...user.emojis};

    // サーバーのカスタム絵文字を取得してマップに追加
    final adapter = account?.adapter;
    if (adapter != null && adapter is CustomEmojiSupport) {
      try {
        final serverEmojis = await (adapter as CustomEmojiSupport).getEmojis();
        for (final e in serverEmojis) {
          allEmojis.putIfAbsent(e.shortcode, () => e.url);
        }
      } catch (e) {
        // 取得失敗時はユーザー絵文字のみでフォールバック。サーバー側 API 変更・
        // rate-limit を breadcrumb で観測可能にする (#553)。
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'compose.emoji.fetch',
            message: e.runtimeType.toString(),
            level: SentryLevel.warning,
          ),
        );
      }
    }
    if (!mounted) return;

    // Collect poll options if enabled.
    final pollOptions = _pollEnabled
        ? _pollControllers
              .map((c) => c.text.trim())
              .where((t) => t.isNotEmpty)
              .toList()
        : <String>[];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final baseStyle = theme.textTheme.bodyMedium ?? const TextStyle();
        final renderer = ContentRenderer(
          baseStyle: baseStyle,
          resolveEmoji: (shortcode) {
            final url = allEmojis[shortcode];
            if (url != null) return url;
            if (user.host != null) {
              return 'https://${user.host}/emoji/$shortcode.webp';
            }
            return null;
          },
          emojiSize: emojiSize,
        );
        final contentSpan = renderer.renderMfm(text);

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Text('プレビュー', style: theme.textTheme.titleMedium),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                ),
                if (_cwEnabled && _cwController.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _cwController.text,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (text.trim().isNotEmpty)
                          SizedBox(
                            width: double.infinity,
                            child: RichText(text: contentSpan),
                          ),
                        if (pollOptions.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          ...pollOptions.map(
                            (option) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: theme.colorScheme.outline,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(option),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${_pollMultiple ? "複数選択可" : "単一選択"}'
                              ' · ${_formatPollDuration(_pollExpiresIn)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                        if (_attachments.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              '添付メディア: ${_attachments.length}件',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _formatPollDuration(int seconds) {
    if (seconds >= 86400) {
      final days = seconds ~/ 86400;
      return '$days日';
    }
    if (seconds >= 3600) {
      final hours = seconds ~/ 3600;
      return '$hours時間';
    }
    return '${seconds ~/ 60}分';
  }

  bool get _effectiveSensitive => _cwEnabled || _sensitiveEnabled;

  Future<void> _pickScheduleDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: '予約投稿の日付',
      confirmText: '次へ（時刻を選択）',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: _scheduledAt != null
          ? TimeOfDay.fromDateTime(_scheduledAt!)
          : TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      helpText: '予約投稿の時刻',
    );
    if (time == null || !mounted) return;

    final scheduled = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    // Mastodon requires at least 5 minutes in the future.
    final minTime = DateTime.now().add(const Duration(minutes: 5));
    if (scheduled.isBefore(minTime)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('5分以上先の日時を指定してください')));
      }
      return;
    }
    setState(() => _scheduledAt = scheduled);
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty && !_pollEnabled) return;

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

    if (_pollEnabled) {
      final filledOptions = _pollControllers
          .map((c) => c.text.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (filledOptions.length < 2) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('選択肢を2つ以上入力してください')));
        return;
      }
    }

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    setState(() => _sending = true);
    try {
      // Upload local attachments / reuse drive file IDs.
      final mediaIds = await Future.wait(
        _attachments.map((entry) async {
          if (entry.isDrive) {
            return entry.driveFile!.id;
          }
          final draft = AttachmentDraft(
            filePath: entry.file!.path,
            description: entry.description.isNotEmpty
                ? entry.description
                : null,
            mimeType: entry.file!.mimeType,
            sensitive: _effectiveSensitive || entry.sensitive,
          );
          final attachment = await adapter.uploadAttachment(draft);
          return attachment.id;
        }),
      );

      final spoilerText = _cwEnabled ? _cwController.text.trim() : null;
      final posted = await adapter.postStatus(
        PostDraft(
          content: text.isNotEmpty ? text : null,
          scope: _scope,
          inReplyToId: widget.replyTo?.id,
          quoteId: widget.quoteTo?.id,
          mediaIds: mediaIds,
          spoilerText: spoilerText?.isNotEmpty == true ? spoilerText : null,
          sensitive: _effectiveSensitive,
          localOnly: _localOnly,
          channelId: _effectiveChannelId,
          scheduledAt: _scheduledAt,
          language: _language,
          pollOptions: _pollEnabled
              ? _pollControllers
                    .map((c) => c.text.trim())
                    .where((t) => t.isNotEmpty)
                    .toList()
              : null,
          pollExpiresIn: _pollEnabled ? _pollExpiresIn : null,
          pollMultiple: _pollEnabled && _pollMultiple,
          quoteApprovalPolicy: _quoteApprovalPolicy,
        ),
      );
      // Posting succeeded — drop any persisted draft so it doesn't reappear
      // the next time the user opens compose. Only applies to fresh-compose
      // sessions; reply/quote/redraft/share flows never autosaved and must
      // not touch an unrelated draft.
      if (_draftAutoSave) {
        await _clearDraft();
      }
      if (mounted) {
        if (_scheduledAt != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('予約投稿を設定しました')));
        } else {
          ref.invalidate(timelineProvider);
          final channelId = _effectiveChannelId;
          if (channelId != null) {
            ref.invalidate(channelTimelineProvider(channelId));
          }
          // #433: hideLivecure ON 中に #実況 を含む投稿をすると TL から
          // 除外されるため SnackBar で告知。検出はモロヘイヤ handler が
          // タグを追記した後の rendered content (= postStatus 戻り値) で
          // 行うため、ユーザー入力に #実況 がない自動付与経路もカバーする。
          maybeShowHideLivecureSnackBar(context, ref, posted);
        }
        if (context.canPop()) {
          context.pop(true);
        } else {
          context.go('/home');
        }
      }
    } catch (e, st) {
      if (!mounted) return;
      if (widget.redraft != null) {
        // 元投稿は既に削除されている。本文をクリップボードに保全し、
        // 再投稿手段をユーザーに提示する (#393)。
        await Clipboard.setData(ClipboardData(text: _controller.text));
        await Sentry.captureException(
          e,
          stackTrace: st,
          withScope: (scope) => scope.setTag('phase', 'redraft_resend_failed'),
        );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('投稿に失敗しました'),
            content: const Text(
              '元の投稿は既に削除されています。本文はクリップボードに'
              'コピーしました。新規作成画面に貼り付けて再投稿してください。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (mounted) setState(() => _sending = false);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${ref.read(postLabelProvider)}に失敗しました')),
        );
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxLength = ref.watch(maxPostLengthProvider);

    return Scaffold(
      appBar: AppBar(
        // Share intent (URL push from macOS Music.app 等) で起動した場合
        // GoRouter の go() で stack が置換されており automatic back button が
        // 出ないため、明示的に leading に置く。_submit 末尾と同じく canPop
        // が false のときは /home にフォールバック (#422)。
        leading: BackButton(
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/home');
            }
          },
        ),
        title: Text(
          widget.replyTo != null
              ? (_effectiveChannelName != null
                    ? 'リプライ：$_effectiveChannelName'
                    : 'リプライ')
              : _effectiveChannelName != null
              ? '${ref.watch(postLabelProvider)}：$_effectiveChannelName'
              : ref.watch(postLabelProvider),
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            onPressed: _sending ? null : _showPreview,
            icon: const Icon(Icons.preview_outlined),
            tooltip: 'プレビュー',
          ),
          IconButton(
            onPressed: _sending ? null : _submit,
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_scheduledAt != null ? Icons.schedule_send : Icons.send),
            tooltip: _scheduledAt != null ? '予約投稿' : null,
          ),
        ],
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (detail) {
          setState(() => _dragging = false);
          _onDragDone(detail);
        },
        child: ColoredBox(
          color: _dragging
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.replyTo != null)
                  _CollapsiblePreview(post: widget.replyTo!, icon: Icons.reply),
                if (widget.quoteTo != null)
                  _CollapsiblePreview(
                    post: widget.quoteTo!,
                    icon: Icons.format_quote,
                  ),
                if (_cwEnabled)
                  TextField(
                    controller: _cwController,
                    enabled: !_sending,
                    decoration: const InputDecoration(
                      hintText: '閲覧注意の警告文',
                      border: UnderlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      TextField(
                        controller: _controller,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        autofocus: true,
                        enabled: !_sending,
                        decoration: const InputDecoration(
                          hintText: '今なにしてる？',
                          border: InputBorder.none,
                        ),
                      ),
                      if (maxLength != null)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: IgnorePointer(
                            child: ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _controller,
                              builder: (context, value, _) {
                                final len = value.text.length;
                                return Text(
                                  '$len / $maxLength',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: len > maxLength
                                        ? Theme.of(context).colorScheme.error
                                        : len > maxLength * 0.8
                                        ? Colors.orange
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant
                                              .withValues(alpha: 0.5),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_mentionSuggestions.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _mentionSuggestions.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 4),
                      itemBuilder: (context, index) {
                        final user = _mentionSuggestions[index];
                        final localHost = ref
                            .read(currentAccountProvider)
                            ?.user
                            .host;
                        final isRemote =
                            user.host != null && user.host != localHost;
                        final label = isRemote
                            ? '@${_buildAcct(user)}'
                            : '@${user.username}';
                        return ActionChip(
                          avatar: user.isGroup
                              ? const Icon(Icons.groups, size: 18)
                              : user.isBot
                              ? const Icon(Icons.smart_toy, size: 18)
                              : user.avatarUrl != null
                              ? CircleAvatar(
                                  backgroundImage: NetworkImage(
                                    user.avatarUrl!,
                                  ),
                                  radius: 12,
                                )
                              : const Icon(Icons.person, size: 18),
                          label: Text(label, overflow: TextOverflow.ellipsis),
                          tooltip: user.isGroup
                              ? 'コミュニティ: @${_buildAcct(user)}'
                              : '@${_buildAcct(user)}',
                          onPressed: () => _insertMention(user),
                        );
                      },
                    ),
                  ),
                if (_hashtagSuggestions.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _hashtagSuggestions.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 4),
                      itemBuilder: (context, index) {
                        final tag = _hashtagSuggestions[index];
                        return ActionChip(
                          avatar: const Icon(Icons.tag, size: 18),
                          label: Text('#$tag', overflow: TextOverflow.ellipsis),
                          onPressed: () => _insertHashtag(tag),
                        );
                      },
                    ),
                  ),
                if (_emojiSuggestions.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _emojiSuggestions.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 4),
                      itemBuilder: (context, index) {
                        final emoji = _emojiSuggestions[index];
                        return ActionChip(
                          avatar: SizedBox(
                            width: 20,
                            height: 20,
                            child: Image.network(
                              emoji.url,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.emoji_emotions, size: 18),
                            ),
                          ),
                          label: Text(
                            ':${emoji.shortcode}:',
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: () => _completeEmojiFromSuggestion(emoji),
                        );
                      },
                    ),
                  ),
                if (_pollEnabled) ...[const Divider(), _buildPollEditor()],
                if (_attachments.isNotEmpty) ...[
                  const Divider(),
                  SizedBox(
                    height: 60,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _attachments.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final entry = _attachments[index];
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _sending
                              ? null
                              : () => _editDescription(index),
                          child: Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: _buildThumbnail(entry),
                              ),
                              // ALT badge
                              if (entry.description.isNotEmpty)
                                Positioned(
                                  bottom: 4,
                                  left: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'ALT',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              // Crop button (デスクトップのローカル静止画のみ)
                              if (_supportsCrop && _isCroppableImage(entry))
                                Positioned(
                                  top: 4,
                                  left: 4,
                                  child: GestureDetector(
                                    onTap: _sending
                                        ? null
                                        : () => _cropImage(index),
                                    child: Container(
                                      decoration: const BoxDecoration(
                                        color: Colors.black54,
                                        shape: BoxShape.circle,
                                      ),
                                      padding: const EdgeInsets.all(4),
                                      child: const Icon(
                                        Icons.crop,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              // Remove button
                              Positioned(
                                top: 4,
                                right: 4,
                                child: GestureDetector(
                                  onTap: _sending
                                      ? null
                                      : () => _removeAttachment(index),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    padding: const EdgeInsets.all(4),
                                    child: const Icon(
                                      Icons.close,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const Divider(),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // ソフトキーボードが出ている時だけ「しまう」ボタンを出す (#594)。
                      // Android ATOK のように IME 側に dismiss ボタンが無い環境向け。
                      // 画面幅でなくソフトキーボード有無で出し分けるため Platform 分岐
                      // 不要 (desktop では viewInsets.bottom が 0 で常に非表示)。
                      //
                      // Scaffold(resizeToAvoidBottomInset:true) は body を
                      // MediaQuery.removeViewInsets でラップするため、body 配下の
                      // ここでは MediaQuery.viewInsets.bottom が 0 に剥がれて常に
                      // 非表示になっていた。simple_post_bar と判定軸を揃え、
                      // View.of(context) で root view から直接拾う (#635 / #630)。
                      if (View.of(context).viewInsets.bottom > 0)
                        IconButton(
                          onPressed: () => FocusScope.of(context).unfocus(),
                          icon: const Icon(Icons.keyboard_hide),
                          tooltip: 'キーボードをしまう',
                          visualDensity: VisualDensity.compact,
                        ),
                      IconButton(
                        onPressed: _sending ? null : _pickMedia,
                        icon: const Icon(Icons.photo),
                        tooltip: 'メディアを添付',
                        visualDensity: VisualDensity.compact,
                      ),
                      if (ref.watch(currentAdapterProvider) is DriveSupport)
                        IconButton(
                          onPressed: _sending ? null : _pickDriveFiles,
                          icon: const Icon(Icons.cloud_outlined),
                          tooltip: 'ドライブ',
                          visualDensity: VisualDensity.compact,
                        ),
                      IconButton(
                        onPressed: _sending ? null : _showEmojiPicker,
                        icon: const Icon(Icons.emoji_emotions_outlined),
                        tooltip: '絵文字',
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        onPressed: _sending
                            ? null
                            : () => setState(() => _cwEnabled = !_cwEnabled),
                        icon: Icon(
                          Icons.warning_amber,
                          color: _cwEnabled
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        tooltip: '閲覧注意',
                        visualDensity: VisualDensity.compact,
                      ),
                      if (ref.watch(currentAdapterProvider) is PollSupport)
                        IconButton(
                          onPressed: _sending
                              ? null
                              : () => setState(
                                  () => _pollEnabled = !_pollEnabled,
                                ),
                          icon: Icon(
                            Icons.poll_outlined,
                            color: _pollEnabled
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          tooltip: 'アンケート',
                          visualDensity: VisualDensity.compact,
                        ),
                      if (_attachments.isNotEmpty)
                        IconButton(
                          onPressed: _sending
                              ? null
                              : () => setState(
                                  () => _sensitiveEnabled = !_sensitiveEnabled,
                                ),
                          icon: Icon(
                            _effectiveSensitive
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: _effectiveSensitive
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          tooltip: '閲覧注意メディア',
                          visualDensity: VisualDensity.compact,
                        ),
                      if (ref.watch(currentMulukhiyaProvider) != null)
                        IconButton(
                          onPressed: _sending ? null : _showTagsetSheet,
                          icon: const Icon(Icons.live_tv),
                          tooltip: '実況',
                          visualDensity: VisualDensity.compact,
                        ),
                      if (ref.watch(currentAdapterProvider) is ScheduleSupport)
                        IconButton(
                          onPressed: _sending ? null : _pickScheduleDate,
                          icon: Icon(
                            Icons.schedule,
                            color: _scheduledAt != null
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          tooltip: '予約投稿',
                          visualDensity: VisualDensity.compact,
                        ),
                      const VerticalDivider(width: 16),
                      DropdownButton<PostScope>(
                        value: _scope,
                        underline: const SizedBox.shrink(),
                        isDense: true,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        onChanged: _sending
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _scope = value);
                                }
                              },
                        items: _scopeItems(ref),
                      ),
                      if (ref.watch(currentAdapterProvider) is ReactionSupport)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: FilterChip(
                            label: const Text('ローカルのみ'),
                            selected: _localOnly,
                            onSelected: _sending
                                ? null
                                : (v) => setState(() => _localOnly = v),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      if (_language != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: DropdownButton<String>(
                            value: _language,
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            onChanged: _sending
                                ? null
                                : (v) {
                                    if (v != null) {
                                      setState(() => _language = v);
                                    }
                                  },
                            items: _languageOptions.entries
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(
                                      e.value,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      if (ref.watch(currentAdapterProvider) is MastodonAdapter)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: DropdownButton<String?>(
                            value: _quoteApprovalPolicy,
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            hint: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.format_quote, size: 16),
                                const SizedBox(width: 4),
                                const Text(
                                  '引用許可',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                            onChanged: _sending
                                ? null
                                : (v) =>
                                      setState(() => _quoteApprovalPolicy = v),
                            items: _quoteApprovalLabels.entries
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _quoteApprovalIcons[e.key],
                                          size: 16,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          e.value,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      if (_scheduledAt != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Chip(
                            avatar: const Icon(Icons.schedule, size: 16),
                            label: Text(
                              '${_scheduledAt!.month}/${_scheduledAt!.day} '
                              '${_scheduledAt!.hour.toString().padLeft(2, '0')}:'
                              '${_scheduledAt!.minute.toString().padLeft(2, '0')}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            onDeleted: _sending
                                ? null
                                : () => setState(() => _scheduledAt = null),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsiblePreview extends StatefulWidget {
  final Post post;
  final IconData icon;

  const _CollapsiblePreview({required this.post, required this.icon});

  @override
  State<_CollapsiblePreview> createState() => _CollapsiblePreviewState();
}

class _CollapsiblePreviewState extends State<_CollapsiblePreview> {
  bool _expanded = false;

  static String _extractPlainText(String content) {
    final isHtml = content.contains('<') && content.contains('>');
    if (!isHtml) return content;
    return stripHtml(content);
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final displayName = post.author.displayName ?? post.author.username;
    final preview = _extractPlainText(post.content ?? '');
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(widget.icon, size: 14, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: _expanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        EmojiText(
                          displayName,
                          emojis: post.author.emojis,
                          fallbackHost: post.emojiHost,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: color,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (preview.isNotEmpty)
                          Text(
                            preview,
                            style: TextStyle(fontSize: 12, color: color),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    )
                  : EmojiText(
                      '$displayName: $preview',
                      emojis: post.author.emojis,
                      fallbackHost: post.emojiHost,
                      style: TextStyle(fontSize: 12, color: color),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 14,
              color: color,
            ),
          ],
        ),
      ),
    );
  }
}

class _TagsetSheet extends StatefulWidget {
  final MulukhiyaService mulukhiya;
  final bool annictEnabled;
  final void Function(MulukhiyaProgram program) onSelect;
  final VoidCallback onClear;
  final VoidCallback? onEpisodeBrowser;
  final void Function(MulukhiyaProgram program) onAnnictRecord;
  final VoidCallback onReload;

  const _TagsetSheet({
    required this.mulukhiya,
    this.annictEnabled = false,
    required this.onSelect,
    required this.onClear,
    this.onEpisodeBrowser,
    required this.onAnnictRecord,
    required this.onReload,
  });

  @override
  State<_TagsetSheet> createState() => _TagsetSheetState();
}

class _TagsetSheetState extends State<_TagsetSheet> {
  Map<String, MulukhiyaProgram>? _programs;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPrograms();
  }

  Future<void> _loadPrograms() async {
    try {
      final programs = await widget.mulukhiya.getProgram();
      if (mounted) {
        setState(() {
          _programs = programs;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _programLabel(MulukhiyaProgram p) {
    final parts = <String>[];
    if (p.series != null) parts.add(p.series!);
    if (p.episode != null) {
      final suffix = (p.episodeSuffix?.isNotEmpty ?? false)
          ? p.episodeSuffix!
          : '話';
      parts.add('${p.episode}$suffix');
    }
    if (p.subtitle != null) parts.add(p.subtitle!);
    return parts.isNotEmpty ? parts.join(' ') : p.name;
  }

  String _programSublabel(MulukhiyaProgram p) {
    final flags = <String>[];
    if (p.air) flags.add('エア番組');
    if (p.livecure) flags.add('実況');
    if (p.minutes != null) flags.add('${p.minutes}分');
    if (p.extraTags.isNotEmpty) flags.addAll(p.extraTags);
    return flags.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '実況タグセット',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('読み込みに失敗しました: $_error'),
            )
          else ...[
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.clear),
                    title: const Text('タグなし'),
                    subtitle: const Text('タグセットを削除し、実況を終了する'),
                    onTap: widget.onClear,
                  ),
                  if (_programs != null)
                    for (final entry in _programs!.entries)
                      ListTile(
                        leading: const Icon(Icons.live_tv),
                        title: Text(_programLabel(entry.value)),
                        subtitle: Text(_programSublabel(entry.value)),
                        // annict_episode_id を持つ番組表エントリは Annict 感想
                        // 投稿への動線も提供する (#298)。判定は ID の有無のみで、
                        // air フラグ (= 公式放送が無い作品を「放送中のテイ」で
                        // 実況する番組) は独立した軸。エア番組も作品自体は実在し
                        // Annict にエントリがあるため annict_episode_id が
                        // 埋まっていれば普通に感想投稿対象になる
                        // (project_air_program_concept)。
                        trailing: entry.value.annictEpisodeId != null
                            ? IconButton(
                                icon: const Icon(Icons.rate_review_outlined),
                                tooltip: 'Annict に感想投稿',
                                onPressed: () =>
                                    widget.onAnnictRecord(entry.value),
                              )
                            : null,
                        onTap: () => widget.onSelect(entry.value),
                      ),
                  if (widget.annictEnabled && widget.onEpisodeBrowser != null)
                    ListTile(
                      leading: const Icon(Icons.video_library),
                      title: const Text('エピソードブラウザ'),
                      onTap: widget.onEpisodeBrowser,
                    ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('番組表を更新'),
                    subtitle: const Text('モロヘイヤから番組表をダウンロードし直す'),
                    onTap: widget.onReload,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
