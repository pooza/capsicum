import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

/// タグ TL の条件を書くダイアログ (#1209)。直した spec を返す（やめたら null）。
///
/// タブ管理とデッキのカラム編集の両方から開く。以前はタブ管理にだけ「AND 条件」の
/// ダイアログがあり、Mastodon でしか開けなかった。
///
/// - **すべて含む**（AND）/ **いずれかを含む**（OR）/ **含まない**（除外）の 3 欄
/// - タグはカンマか空白で区切る。先頭の `#` は付けても付けなくてもよい
/// - ⚠ `+` は区切りにしない —— Misskey のタグは `+` を含みうる（`#c++`）
///
/// ⚠ **含む側が 1 つも無い条件は保存させない。**除外だけでは TL にならない
/// （全投稿から引くことになる）。
Future<String?> showHashtagConditionDialog(BuildContext context, String spec) =>
    showDialog<String>(
      context: context,
      builder: (_) =>
          _HashtagConditionDialog(initial: HashtagQuery.parse(spec)),
    );

/// 入力欄の文字列をタグの列にする。カンマ・読点・空白で区切り、先頭の `#` を外す。
@visibleForTesting
List<String> parseHashtagConditionInput(String input) => [
  for (final piece in input.split(RegExp(r'[,、\s]+')))
    if (piece.replaceFirst(RegExp('^[#＃]'), '').trim() case final tag
        when tag.isNotEmpty)
      tag,
];

class _HashtagConditionDialog extends StatefulWidget {
  const _HashtagConditionDialog({required this.initial});

  final HashtagQuery initial;

  @override
  State<_HashtagConditionDialog> createState() =>
      _HashtagConditionDialogState();
}

class _HashtagConditionDialogState extends State<_HashtagConditionDialog> {
  late final _all = TextEditingController(text: widget.initial.all.join(', '));
  late final _any = TextEditingController(text: widget.initial.any.join(', '));
  late final _none = TextEditingController(
    text: widget.initial.none.join(', '),
  );
  String? _error;

  @override
  void dispose() {
    _all.dispose();
    _any.dispose();
    _none.dispose();
    super.dispose();
  }

  void _submit() {
    final query = HashtagQuery(
      all: parseHashtagConditionInput(_all.text),
      any: parseHashtagConditionInput(_any.text),
      none: parseHashtagConditionInput(_none.text),
    );
    if (query.isEmpty) {
      setState(() => _error = '「すべて含む」か「いずれかを含む」に、タグを 1 つ以上入れてください');
      return;
    }
    Navigator.pop(context, query.toSpec());
  }

  Widget _field(
    TextEditingController controller, {
    required String label,
    required String helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      textInputAction: TextInputAction.next,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('タグの条件'),
      // ⚠ 3 欄 + 説明で縦に長い。キーボードが出ると収まらないので流せるようにする。
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('タグはカンマで区切って入力します。'),
          const SizedBox(height: 16),
          _field(_all, label: 'すべて含む', helper: 'ここに書いたタグを全部含む投稿'),
          _field(_any, label: 'いずれかを含む', helper: 'ここに書いたタグのどれか 1 つでも含む投稿'),
          _field(_none, label: '含まない', helper: 'ここに書いたタグを含む投稿は出さない'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
