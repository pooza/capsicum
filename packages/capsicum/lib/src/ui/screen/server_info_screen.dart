import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:html_unescape/html_unescape.dart';
import '../../provider/server_info_provider.dart';
import '../../url_helper.dart';
import '../widget/emoji_text.dart';
import '../widget/user_avatar.dart';

class ServerInfoScreen extends ConsumerWidget {
  const ServerInfoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(serverInfoProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('サーバー情報'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('読み込みに失敗しました\n$error')),
        data: (state) => _buildContent(context, ref, state),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    ServerInfoState state,
  ) {
    final instance = state.instance;
    if (instance == null) {
      return const Center(child: Text('サーバー情報を取得できませんでした'));
    }

    final colorScheme = Theme.of(context).colorScheme;

    return ListView(
      children: [
        // Basic info
        _SectionHeader(title: '基本情報'),
        ListTile(
          leading: instance.iconUrl != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    instance.iconUrl!,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.dns, size: 40),
                  ),
                )
              : const Icon(Icons.dns, size: 40),
          title: Text(instance.name),
          subtitle: Text(
            [
              if (instance.softwareName != null) instance.softwareName!,
              if (instance.version != null) 'v${instance.version}',
            ].join(' '),
          ),
        ),
        if (instance.description != null && instance.description!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _HtmlText(html: instance.description!),
          ),
        if (instance.userCount != null || instance.postCount != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Wrap(
              spacing: 16,
              children: [
                if (instance.userCount != null)
                  Text('ユーザー: ${instance.userCount}'),
                if (instance.postCount != null)
                  Text('投稿: ${instance.postCount}'),
              ],
            ),
          ),

        // Contact
        if (instance.contactAccount != null ||
            instance.contactEmail != null ||
            instance.contactUrl != null) ...[
          _SectionHeader(title: '連絡先'),
          if (instance.contactAccount != null)
            ListTile(
              leading: UserAvatar(
                user: instance.contactAccount!,
                size: 40,
                borderRadius: 4,
              ),
              title: EmojiText(
                instance.contactAccount!.displayName ??
                    instance.contactAccount!.username,
                emojis: instance.contactAccount!.emojis,
                fallbackHost: instance.contactAccount!.host,
              ),
              onTap: () =>
                  context.push('/profile', extra: instance.contactAccount),
            ),
          if (instance.contactEmail != null)
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: Text(instance.contactEmail!),
              subtitle: const Text('タップでコピー'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: instance.contactEmail!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('メールアドレスをコピーしました'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          if (instance.contactUrl != null)
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(instance.contactUrl!),
              onTap: () => launchUrlSafely(
                Uri.parse(instance.contactUrl!),
                mode: LaunchMode.externalApplication,
              ),
            ),
        ],

        // Rules
        if (instance.rules.isNotEmpty) ...[
          _SectionHeader(title: 'ルール'),
          ...instance.rules.asMap().entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${entry.key + 1}.',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  Expanded(child: _HtmlText(html: entry.value)),
                ],
              ),
            ),
          ),
        ],

        // Links
        if (instance.privacyPolicyUrl != null &&
            Uri.tryParse(instance.privacyPolicyUrl!) != null &&
            instance.privacyPolicyUrl!.startsWith('http')) ...[
          _SectionHeader(title: 'ポリシー'),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('プライバシーポリシー'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrlSafely(
              Uri.parse(instance.privacyPolicyUrl!),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],

        // Health checks
        _SectionHeader(title: 'ヘルスチェック'),
        if (state.healthChecks.isEmpty && !state.isCheckingHealth)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FilledButton.icon(
              onPressed: () =>
                  ref.read(serverInfoProvider.notifier).runHealthChecks(),
              icon: const Icon(Icons.play_arrow),
              label: const Text('実行'),
            ),
          )
        else if (state.isCheckingHealth)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          ...state.healthChecks.map(
            (check) => ListTile(
              leading: Icon(
                check.ok ? Icons.check_circle : Icons.error,
                color: check.ok ? Colors.green : colorScheme.error,
              ),
              title: Text(check.name),
              subtitle: check.responseTime != null
                  ? Text('${check.responseTime!.inMilliseconds}ms')
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextButton.icon(
              onPressed: () =>
                  ref.read(serverInfoProvider.notifier).runHealthChecks(),
              icon: const Icon(Icons.refresh),
              label: const Text('再実行'),
            ),
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

final _unescape = HtmlUnescape();

/// Lightweight HTML text widget that handles <br>, <a>, and strips other tags.
class _HtmlText extends StatelessWidget {
  final String html;
  const _HtmlText({required this.html});

  @override
  Widget build(BuildContext context) {
    final spans = _parse(context);
    return Text.rich(TextSpan(children: spans));
  }

  List<InlineSpan> _parse(BuildContext context) {
    final linkColor = Theme.of(context).colorScheme.primary;
    final spans = <InlineSpan>[];
    // Process <br> and </p><p> first.
    var processed = html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n');

    // Extract <a> tags, convert rest to plain text.
    final pattern = RegExp(r'<a\s[^>]*href="([^"]*)"[^>]*>(.*?)</a>');
    var lastEnd = 0;
    for (final match in pattern.allMatches(processed)) {
      // Text before the link.
      if (match.start > lastEnd) {
        final text = _strip(processed.substring(lastEnd, match.start));
        if (text.isNotEmpty) spans.add(TextSpan(text: text));
      }
      // The link itself.
      final url = match.group(1)!;
      final label = _strip(match.group(2)!);
      spans.add(
        TextSpan(
          text: label.isNotEmpty ? label : url,
          style: TextStyle(
            color: linkColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => launchUrlSafely(
              Uri.parse(url),
              mode: LaunchMode.externalApplication,
            ),
        ),
      );
      lastEnd = match.end;
    }
    // Remaining text after last link.
    if (lastEnd < processed.length) {
      final text = _strip(processed.substring(lastEnd));
      if (text.isNotEmpty) spans.add(TextSpan(text: text));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: _strip(processed)));
    return spans;
  }

  String _strip(String s) =>
      _unescape.convert(s.replaceAll(RegExp(r'<[^>]*>'), ''));
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
