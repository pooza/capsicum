import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../util/compose_text_style.dart';

/// 通報ダイアログの入力 (#1203 / #1257)。
typedef ReportInput = ({
  String comment,
  bool forward,
  ReportCategory category,
  List<String> ruleIds,
});

/// 分類の表示名 (#1257)。
const reportCategoryLabels = {
  ReportCategory.other: 'その他',
  ReportCategory.spam: 'スパム',
  ReportCategory.legal: '違法な内容',
  ReportCategory.violation: 'サーバーのルール違反',
};

/// [showReportCommentDialog] の `rules` に渡す値 (#1257)。分類を添えられる
/// バックエンドだけルールを読み、それ以外は null（分類を出さない）。
///
/// ⚠ 投稿の通報とプロフィールの通報の 2 か所で使う。判定を写さない。
Future<List<ReportRule>>? reportRulesFor(ReportSupport adapter) =>
    adapter.supportsReportCategory ? adapter.getReportRules() : null;

/// 通報の確認ダイアログ (#998)。理由を任意で添えられる。
///
/// 返すのは入力された理由（空文字もありうる）と転送の指定で、キャンセルは null。
///
/// [forwardHost] は通報を転送できる先のサーバー (#1203)。渡すと「相手の
/// サーバーの管理者にも知らせる」のチェックを出す。
/// ⚠ **既定はオン。**転送しない通報は自分のサーバーの管理者にしか届かず、
/// リモートの相手を止められる人（相手のサーバーの管理者）には伝わらない。
/// WebUI もリモートの相手では既定でオンにしている。
/// ⚠ **null のときは出さない**（ローカルの相手・転送の口が無いバックエンド）。
/// 返る `forward` は常に false。
///
/// ⚠ **controller はダイアログ自身が持つ (Codex P2 / PR #1013)。**
/// `showDialog` の Future は**閉じるアニメーションの完了より前に**解決するため、
/// 呼び出し側で `finally` 破棄すると、まだツリーに残っている `TextField` が
/// 破棄済み controller に触れる。呼び出し側が持つ形にしていた 2 画面
/// （投稿の通報 / プロフィールの通報）で、片方は早すぎる破棄、もう片方は破棄
/// 漏れになっていたので、寿命ごとここへ寄せる。
///
/// [rules] を渡すと分類を選べるようにする (#1257・2026-10-27 pooza 判断)。
/// 渡さなければ（Misskey）出さず、返る分類は常に「その他」。
/// ⚠ **既定は「その他」**で、触らなければ分類を足す前と同じ手数で送れる。
/// ⚠⚠ 「サーバーのルール違反」は、ルールが読めて 1 件以上あるときだけ出し、
/// 選んだらルールを 1 つ以上選ぶまで送れない（添えずに送るとサーバーが断る）。
/// ルールはダイアログを開いてから読む（開くのを待たせない）。
Future<ReportInput?> showReportCommentDialog(
  BuildContext context, {
  required String message,
  String? forwardHost,
  Future<List<ReportRule>>? rules,
}) => showDialog<ReportInput>(
  context: context,
  builder: (_) => _ReportCommentDialog(
    message: message,
    forwardHost: forwardHost,
    rules: rules,
  ),
);

class _ReportCommentDialog extends StatefulWidget {
  const _ReportCommentDialog({
    required this.message,
    this.forwardHost,
    this.rules,
  });

  final String message;
  final String? forwardHost;
  final Future<List<ReportRule>>? rules;

  @override
  State<_ReportCommentDialog> createState() => _ReportCommentDialogState();
}

class _ReportCommentDialogState extends State<_ReportCommentDialog> {
  final _controller = TextEditingController();
  late bool _forward = widget.forwardHost != null;
  ReportCategory _category = ReportCategory.other;

  /// 読めたルール。読み込み中・読めなかったときは空。
  List<ReportRule> _rules = const [];
  final _selectedRuleIds = <String>{};

  @override
  void initState() {
    super.initState();
    widget.rules
        ?.then((rules) {
          if (mounted) setState(() => _rules = rules);
        })
        .catchError((Object _) {
          // 読めなければ「サーバーのルール違反」を出さないだけ。
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _category != ReportCategory.violation || _selectedRuleIds.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final forwardHost = widget.forwardHost;
    final categories = [
      ReportCategory.other,
      ReportCategory.spam,
      ReportCategory.legal,
      if (_rules.isNotEmpty) ReportCategory.violation,
    ];
    return AlertDialog(
      title: const Text('通報'),
      // 小さい画面でキーボードが出ると、チェックのぶんだけ縦が足りなくなる。
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.message),
            const SizedBox(height: 12),
            if (widget.rules != null) ...[
              DropdownButtonFormField<ReportCategory>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: '分類',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final category in categories)
                    DropdownMenuItem(
                      value: category,
                      child: Text(reportCategoryLabels[category]!),
                    ),
                ],
                onChanged: (v) =>
                    setState(() => _category = v ?? ReportCategory.other),
              ),
              if (_category == ReportCategory.violation) ...[
                const SizedBox(height: 4),
                for (final rule in _rules)
                  CheckboxListTile(
                    value: _selectedRuleIds.contains(rule.id),
                    onChanged: (v) => setState(() {
                      if (v ?? false) {
                        _selectedRuleIds.add(rule.id);
                      } else {
                        _selectedRuleIds.remove(rule.id);
                      }
                    }),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(rule.text),
                    subtitle: rule.hint == null ? null : Text(rule.hint!),
                  ),
                if (_selectedRuleIds.isEmpty)
                  Text(
                    '違反したルールを 1 つ以上選んでください',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
              const SizedBox(height: 12),
            ],
            Consumer(
              builder: (context, ref, _) => TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  hintText: '理由（任意）',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                style: composeTextStyle(ref),
                // ⚠ **client で止める (#1012)。**超えるとサーバーが 400 / 422 で
                // 断り、画面には「通報に失敗しました」しか出ないので、理由も
                // 分からず書いた文章も失われる。上限の根拠は
                // [InputLimits.reportComment]。
                maxLength: InputLimits.reportComment,
              ),
            ),
            if (forwardHost != null)
              CheckboxListTile(
                value: _forward,
                onChanged: (v) => setState(() => _forward = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('$forwardHost の管理者にも知らせる'),
                subtitle: const Text('外すと、このサーバーの管理者にだけ届きます'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: _canSubmit
              ? () => Navigator.pop(context, (
                  comment: _controller.text.trim(),
                  forward: forwardHost != null && _forward,
                  category: _category,
                  // ⚠ ルールは「違反」のときだけ返す（ほかの分類で送ると、
                  // サーバーが分類を「違反」に書き換える）。
                  ruleIds: _category == ReportCategory.violation
                      ? [
                          for (final rule in _rules)
                            if (_selectedRuleIds.contains(rule.id)) rule.id,
                        ]
                      : const <String>[],
                ))
              : null,
          child: const Text('通報'),
        ),
      ],
    );
  }
}
