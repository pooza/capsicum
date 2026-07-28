import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../service/sentry_play_result.dart';
import '../../service/tco_resolver.dart';
import '../flash/flash_result_digest.dart';
import '../../util/misskey_api_error.dart';
import '../../util/oauth_scope_error.dart';
import '../flash/flash_runtime.dart';
import '../flash/flash_view.dart';
import '../util/fediverse_link.dart';
import '../util/flash_error.dart';
import '../../url_helper.dart';
import '../util/hashtag_actions.dart';
import '../widget/content_parser.dart';
import '../widget/emoji_text.dart';
import '../widget/user_avatar.dart';

/// Misskey Flash（UI 表記は **Play**）の詳細画面 (#830)。
///
/// #73 では一覧から外部ブラウザに投げていたが、AiScript をネイティブ実行して
/// `Ui:` 由来の描画ツリーをそのまま widget として表示する。
///
/// ドロワーからの導線は「クイックチューザ（ボトムシート）で 1 本選び、
/// 滞在する行き先はこの独立画面」という #805 の様式に従う。
class FlashViewScreen extends ConsumerStatefulWidget {
  const FlashViewScreen({super.key, this.initialFlash, this.flashId})
    : assert(
        initialFlash != null || flashId != null,
        'either initialFlash or flashId must be provided',
      );

  /// 一覧から遷移する経路（取得済みを渡す）。
  final Flash? initialFlash;

  /// id だけ分かっている経路。
  final String? flashId;

  @override
  ConsumerState<FlashViewScreen> createState() => _FlashViewScreenState();
}

class _FlashViewScreenState extends ConsumerState<FlashViewScreen> {
  late Future<Flash> _future;
  bool _resolving = true;

  @override
  void initState() {
    super.initState();
    _future = _trackResolve();
  }

  Future<Flash> _trackResolve() async {
    _resolving = true;
    try {
      return await _resolve();
    } finally {
      _resolving = false;
    }
  }

  Future<Flash> _resolve() async {
    try {
      // 一覧 (flash/featured) のレスポンスにも script は含まれるが、経路に
      // よっては欠けうるので、その場合だけ show で取り直す。
      final initial = widget.initialFlash;
      if (initial != null && initial.script.isNotEmpty) return initial;

      final raw = ref.read(currentAdapterProvider);
      if (raw is! FlashSupport) {
        throw StateError('current adapter does not support Flash');
      }
      return await (raw as FlashSupport).getFlashById(
        initial?.id ?? widget.flashId!,
      );
    } catch (e, st) {
      reportFlashOpFailure(
        'view',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: FutureBuilder<Flash>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            // snapshot.error はそのまま出さない。Misskey の URL には
            // ?i=<accessToken> が載るため (#460 同型)。
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Play の読み込みに失敗しました',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _resolving
                          ? null
                          : () => setState(() => _future = _trackResolve()),
                      child: const Text('再試行'),
                    ),
                  ],
                ),
              ),
            );
          }
          return _FlashBody(flash: snapshot.data!);
        },
      ),
    );
  }
}

class _FlashBody extends ConsumerStatefulWidget {
  const _FlashBody({required this.flash});

  final Flash flash;

  @override
  ConsumerState<_FlashBody> createState() => _FlashBodyState();
}

class _FlashBodyState extends ConsumerState<_FlashBody> {
  FlashRuntime? _runtime;
  FlashRuntimeError? _error;
  ContentRenderer? _summaryRenderer;
  // summary の ContentRenderer は入力（絵文字サイズ・MFM アニメ・テーマ輝度）が
  // 変わったときだけ作り直す（#628 の _Mfm invariant）。いいねトグルの setState で
  // 毎 build 作り直すと gesture recognizer を無駄に dispose/再生成する (#874)。
  double? _summaryEmojiSize;
  bool? _summaryAnimateMfm;
  Brightness? _summaryBrightness;
  bool _running = false;

  late bool _isLiked = widget.flash.isLiked;
  late int _likedCount = widget.flash.likedCount;
  bool _toggling = false;

  String? get _host {
    final adapter = ref.read(currentAdapterProvider);
    return adapter is DecentralizedBackendAdapter ? adapter.host : null;
  }

  /// 初回実行を 1 度だけ発火させるためのフラグ。[_running] は非同期に立つので
  /// build の再入判定には使えない。
  bool _started = false;

  @override
  void dispose() {
    _runtime?.dispose();
    _summaryRenderer?.dispose();
    super.dispose();
  }

  Future<void> _navigateToMention(String mention) async {
    final parts = mention.replaceFirst('@', '').split('@');
    if (parts.isEmpty) return;
    final username = parts[0];
    final host = parts.length > 1 ? parts[1] : null;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    try {
      final user = await adapter.getUser(username, host);
      if (user != null && mounted) {
        context.push('/profile', extra: user);
      }
    } on Exception catch (e) {
      debugPrint('Failed to look up mention $mention: $e');
    }
  }

  /// Play の説明文（summary）を投稿本文と同じレンダリングで出す。acct / URL /
  /// ハッシュタグ / カスタム絵文字を含みうるので、素の [Text] では shortcode や
  /// 生 URL がそのまま見えてしまう。プロフィールの bio と同型 (#830)。
  Widget _buildSummary(Flash flash, ThemeData theme) {
    final emojiSize = ref.watch(emojiSizeProvider);
    final animateMfm = ref.watch(mfmAnimationEnabledProvider);
    final brightness = theme.brightness;
    // 入力が変わったときだけ作り直す（#628 の _Mfm invariant）。summary は
    // widget.flash 固定なので、実質 emojiSize/animateMfm/テーマ変更時のみ。
    if (_summaryRenderer == null ||
        _summaryEmojiSize != emojiSize ||
        _summaryAnimateMfm != animateMfm ||
        _summaryBrightness != brightness) {
      _summaryRenderer?.dispose();
      final host = _host;
      _summaryRenderer = ContentRenderer(
        baseStyle: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        resolveEmoji: (shortcode) {
          final url = flash.author.emojis[shortcode];
          if (url != null) return url;
          if (host != null) return 'https://$host/emoji/$shortcode.webp';
          return null;
        },
        resolveUrl: (url) =>
            TcoResolver.isTcoUrl(url) ? TcoResolver.getCached(url) : null,
        onLinkTap: (url) => openFediverseLink(context, ref, url),
        onHashtagTap: (tag) => showHashtagActionMenu(context, tag),
        onMentionTap: (mention) => _navigateToMention(mention),
        emojiSize: emojiSize,
        animateMfm: animateMfm,
      );
      _summaryEmojiSize = emojiSize;
      _summaryAnimateMfm = animateMfm;
      _summaryBrightness = brightness;
    }
    return Text.rich(_summaryRenderer!.renderMfm(flash.summary!));
  }

  /// 互換性を承知で degrade を無視し、従来どおりネイティブ実行する (#881)。
  /// 一度立てたら「もう一度実行」でも維持する。
  bool _forceRun = false;

  /// degrade 画面の「このまま実行する」から呼ぶ。以降のこの Play の実行は
  /// 言語バージョンゲートを飛ばす。
  void _forceRunStart() {
    _forceRun = true;
    _start();
  }

  Future<void> _start() async {
    if (_running) return;

    // 新しい AiScript（1.0.0 以上を宣言する Play）は capsicum の評価器
    // （0.16 相当）で実行すると本家と結果がズレうるため、既定では評価せず
    // ブラウザ導線へ degrade する (#881)。ただし従来はネイティブ実行できていた
    // ため、実行できなくなるのは体験の後退。degrade 画面から「このまま実行する」
    // を選べば _forceRun が立ち、互換性を承知で従来どおり評価する。
    if (FlashRuntime.isScriptLangUnsupported(widget.flash.script) &&
        !_forceRun) {
      if (!mounted) return;
      // degrade を踏んだ頻度と、誤ブロック（正当な Play の過剰発火）を測る計装
      // （リリース前レビュー黄）。失敗ではないので info の captureMessage。
      reportPlayDegrade(flashId: widget.flash.id, host: _host);
      setState(() {
        _error = FlashRuntimeError(
          'この Play は新しい AiScript で書かれています',
          'capsicum の評価器では結果が本家と変わる可能性があります。'
              'ブラウザで開くと本家どおりに楽しめます。'
              'このまま実行することもできます（結果が変わる場合があります）。',
          langUnsupported: true,
        );
      });
      return;
    }

    final host = _host;
    if (host == null) {
      // アカウント切替等で現在の adapter が Misskey でなくなった。無言 return だと
      // 「もう一度実行」「再試行」が反応しない dead-tap になるため理由を出す。
      // ブラウザ導線は Play の origin（author.host）へ別途フォールバックする (#874)。
      if (!mounted) return;
      setState(() {
        _error = FlashRuntimeError(
          'この Play を実行できません',
          'Misskey アカウントに切り替えてからお試しください。',
        );
      });
      return;
    }

    final account = ref.read(currentAccountProvider);
    final emojis = ref.read(customEmojisProvider).valueOrNull ?? const [];
    final runtime = FlashRuntime(
      flashId: widget.flash.id,
      host: host,
      customEmojis: [
        for (final e in emojis) (name: e.shortcode, category: e.category),
      ],
      userId: account?.user.id,
      userName: account?.user.displayName ?? account?.user.username,
      userUsername: account?.user.username,
    );
    runtime.onCallbackError = (error, stackTrace) {
      reportFlashOpFailure('callback', error, stackTrace, account: account);
      // ボタンの onClick 失敗は Sentry に出るがユーザーには無反応で dead-tap と
      // 区別がつかない。軽い SnackBar で「押したが失敗した」ことを伝える (#874)。
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ボタンの処理でエラーが起きました')));
      }
    };

    setState(() {
      _running = true;
      _error = null;
      _runtime?.dispose();
      _runtime = runtime;
    });

    try {
      await runtime.run(widget.flash.script);
      // 中断（画面を閉じて dispose→interpreter.abort）されたランは aiscript が
      // 例外を投げず正常終了扱いになる。unmount 済みなら部分的な出目を「成功」と
      // して #898 実験に記録しないよう、ここで打ち切る（リリース前レビュー黄）。
      if (!mounted) return;
      // #898: 成功した実行の「出目」を追跡記録する（前向き実験・記憶非依存）。
      // 絵文字追加の前後で「対象集合と交差する Play だけ出目が変わる」を予測と
      // 突き合わせるための材料。記録の失敗で Play を巻き込まないよう握りつぶす。
      _reportResult(runtime, host);
    } on FlashRuntimeError catch (e, st) {
      // 分類済みの失敗も Sentry へ流す。どの `Ui:` / `Mk:` が未実装かを
      // `flash.unimplemented` タグに載せ、issue は集約したまま機能別に件数
      // 比較・絞り込みできるようにする (#830 / #875)。
      reportFlashOpFailure(
        'run',
        e,
        st,
        account: account,
        tags: e.unimplementedKey != null
            ? {'flash.unimplemented': e.unimplementedKey!}
            : null,
      );
      if (!mounted) return;
      setState(() => _error = e);
    } catch (e, st) {
      // run() が正規化するのは RuntimeError / AiScriptError のみ。StackOverflow
      // 等の非正規化エラーで画面がブランク（body 無し + 「もう一度実行」だけ）に
      // ならないよう、ここで総括して文言を出しつつ観測する。
      reportFlashOpFailure('run', e, st, account: account);
      if (!mounted) return;
      setState(() => _error = FlashRuntimeError('この Play の実行でエラーが起きました', ''));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// 成功した実行の出目とインベントリ版を Sentry へ記録する (#898)。
  /// 追跡が本来の Play 動作を壊さないよう、指紋計算まで含め例外は握りつぶす。
  void _reportResult(FlashRuntime runtime, String host) {
    try {
      reportPlayResult(
        flashId: runtime.flashId,
        host: host,
        inventory: playEmojiInventoryDigest(runtime.customEmojis),
        resultDigest: playResultDigest(runtime.rootChildren, runtime.component),
        // force-run（互換性無視の実行）は評価器レジームが通常と異なるため
        // タグで分離する（#881 / #898 の突合汚染防止）。
        forced: _forceRun,
      );
    } catch (_) {
      // 追跡記録は best-effort。
    }
  }

  Future<void> _toggleLike() async {
    if (_toggling) return;
    final raw = ref.read(currentAdapterProvider);
    if (raw is! FlashSupport) return;
    final flashes = raw as FlashSupport;

    final wasLiked = _isLiked;
    setState(() {
      _toggling = true;
      _isLiked = !wasLiked;
      _likedCount += wasLiked ? -1 : 1;
    });
    try {
      if (wasLiked) {
        await flashes.unlikeFlash(widget.flash.id);
      } else {
        await flashes.likeFlash(widget.flash.id);
      }
    } catch (e, st) {
      final code = misskeyApiErrorCode(e);
      // 非べき等な結果コードは「成功」として楽観状態を確定させる (#873)。stale な
      // _isLiked でタップした結果がサーバー真値と一致しただけなので、巻き戻さず・
      // Sentry にも流さない（失敗ではない）。ALREADY_LIKED=既にいいね済み、
      // NOT_LIKED=既に未いいね。
      if (!wasLiked && code == 'ALREADY_LIKED') return;
      if (wasLiked && code == 'NOT_LIKED') return;

      if (!mounted) return;
      // ここから先は本当に反映されなかったので楽観状態を巻き戻す。
      setState(() {
        _isLiked = wasLiked;
        _likedCount += wasLiked ? 1 : -1;
      });

      // 自分の Play へのいいねは仕様上不可 (#873)。専用文言で知らせる。
      if (code == 'YOUR_FLASH') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('自分の Play にはいいねできません')));
        return;
      }

      // 旧トークン (write:flash-likes 未付与) の 403 は再ログインで直る既知条件。
      // 失敗ではないので Sentry には流さず、再ログイン導線だけ出す (#877 / #615 同型)。
      if (isOAuthScopeError(e)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('権限が不足しています。再ログインしてください')));
        return;
      }

      // それ以外の想定外失敗のみ観測する。
      reportFlashOpFailure(
        wasLiked ? 'unlike' : 'like',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('いいねの更新に失敗しました')));
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  /// 絵文字取得のみをやり直す。解決して AsyncData になれば build 側の開始
  /// ゲートが _start を発火する (#882)。
  void _retryEmojis() {
    setState(() => _started = false);
    ref.invalidate(customEmojisProvider);
  }

  @override
  Widget build(BuildContext context) {
    final flash = widget.flash;
    final theme = Theme.of(context);
    final runtime = _runtime;

    // カスタム絵文字のロード完了を待ってから実行する。実在の Play には
    // CUSTOM_EMOJIS を必須で使うものがあり、空で走らせると結果が変わる。
    // ここを didChangeDependencies + read で書くと、初回 build 時点では
    // AsyncLoading なので発火せず、解決後も再評価されないため **スクリプトが
    // 永久に実行されない**。watch して解決後の rebuild を拾うこと。
    final emojis = ref.watch(customEmojisProvider);
    // 開始は AsyncData のみに絞る。AsyncError も isLoading==false のため、旧
    // `!emojis.isLoading` 判定だと `/api/emojis` 失敗時に開始してしまい、
    // CUSTOM_EMOJIS 依存の Play が空集合で別結果を「成功したように」計算する
    // (#882)。読み込み失敗は下の switch で再試行導線を出す。
    final emojisLoadFailed = emojis is AsyncError;
    if (!_started && emojis is AsyncData) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                flash.title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (flash.summary != null && flash.summary!.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildSummary(flash, theme),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  UserAvatar(user: flash.author, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: EmojiText(
                      flash.author.displayName?.isNotEmpty == true
                          ? flash.author.displayName!
                          : flash.author.username,
                      emojis: flash.author.emojis,
                      fallbackHost: _host,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _toggling ? null : _toggleLike,
                    icon: Icon(
                      _isLiked ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                      color: _isLiked ? theme.colorScheme.primary : null,
                    ),
                    label: Text('$_likedCount'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: switch ((_running, _error, runtime)) {
            (true, _, _) => const Center(child: CircularProgressIndicator()),
            (_, final FlashRuntimeError error, _) => _RunError(
              error: error,
              // Play の origin は author.host。アカウント切替で current adapter が
              // 別ホスト/非 Misskey でも、ブラウザ導線が行き止まらないよう
              // author.host を優先する (#874)。
              host: flash.author.host ?? _host,
              flashId: flash.id,
              onRetry: _start,
              // 新しい AiScript ゆえの degrade のときだけ「このまま実行する」を
              // 出す (#881)。通常の実行エラーには出さない。
              onForceRun: error.langUnsupported ? _forceRunStart : null,
            ),
            (_, _, final FlashRuntime r) => FlashView(runtime: r),
            // 絵文字取得に失敗したまま実行すると別結果になるため、開始せず
            // 再試行導線を出す (#882)。再試行は絵文字取得のみやり直す。
            _ when emojisLoadFailed => _RunError(
              error: FlashRuntimeError(
                'カスタム絵文字を読み込めませんでした',
                'この Play は絵文字を使うため、読み込めないまま実行すると結果が'
                    '変わります。再試行してください。',
              ),
              host: flash.author.host ?? _host,
              flashId: flash.id,
              onRetry: _retryEmojis,
            ),
            // 絵文字ロード中（開始前）はスピナー。ここで「もう一度実行」を
            // 出すと空集合実行を誘発しうるため下のボタンは runtime 確定後のみ。
            _ when emojis.isLoading => const Center(
              child: CircularProgressIndicator(),
            ),
            _ => const SizedBox.shrink(),
          },
        ),
        // 「もう一度実行」は一度実行が確定した後だけ出す（runtime 非 null）。
        // 開始前・絵文字ロード中/失敗時に出すと空集合実行を誘発する (#882)。
        if (runtime != null && _error == null && !_running)
          Center(
            child: TextButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('もう一度実行'),
            ),
          ),
      ],
    );
  }
}

class _RunError extends StatelessWidget {
  const _RunError({
    required this.error,
    required this.host,
    required this.flashId,
    required this.onRetry,
    this.onForceRun,
  });

  final FlashRuntimeError error;
  final String? host;
  final String flashId;
  final VoidCallback onRetry;

  /// 新しい AiScript 宣言ゆえの degrade でだけ渡される「このまま実行する」導線
  /// (#881)。null のときはボタンを出さない。
  final VoidCallback? onForceRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(Icons.error_outline, color: theme.colorScheme.error),
        const SizedBox(height: 8),
        Text(error.summary, textAlign: TextAlign.center),
        if (error.detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            error.detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            // degrade（新しい AiScript）では「再試行」は再度 degrade するだけで
            // 意味がないので出さない。通常のエラーでだけ出す。
            if (onForceRun == null)
              TextButton(onPressed: onRetry, child: const Text('再試行')),
            // capsicum が実行できない Play でも、本家の web UI なら動く。
            // 行き止まりにしない。
            if (host != null)
              TextButton.icon(
                onPressed: () => launchUrlSafely(
                  Uri.parse('https://$host/play/$flashId'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('ブラウザで開く'),
              ),
            // 新しい AiScript ゆえの degrade でだけ、互換性を承知で従来どおり
            // ネイティブ実行する逃げ道を出す (#881)。ブロックで体験を後退させ
            // ないため。
            if (onForceRun != null)
              TextButton.icon(
                onPressed: onForceRun,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('このまま実行する'),
              ),
          ],
        ),
      ],
    );
  }
}
