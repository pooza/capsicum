import 'package:flutter/material.dart';

import '../../constants.dart';

/// 通報の確認ダイアログ (#998)。理由を任意で添えられる。
///
/// 返すのは入力された理由（空文字もありうる）で、キャンセルは null。
///
/// ⚠ **controller はダイアログ自身が持つ (Codex P2 / PR #1013)。**
/// `showDialog` の Future は**閉じるアニメーションの完了より前に**解決するため、
/// 呼び出し側で `finally` 破棄すると、まだツリーに残っている `TextField` が
/// 破棄済み controller に触れる。呼び出し側が持つ形にしていた 2 画面
/// （投稿の通報 / プロフィールの通報）で、片方は早すぎる破棄、もう片方は破棄
/// 漏れになっていたので、寿命ごとここへ寄せる。
Future<String?> showReportCommentDialog(
  BuildContext context, {
  required String message,
}) => showDialog<String>(
  context: context,
  builder: (_) => _ReportCommentDialog(message: message),
);

class _ReportCommentDialog extends StatefulWidget {
  const _ReportCommentDialog({required this.message});

  final String message;

  @override
  State<_ReportCommentDialog> createState() => _ReportCommentDialogState();
}

class _ReportCommentDialogState extends State<_ReportCommentDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('通報'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.message),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          decoration: const InputDecoration(
            hintText: '理由（任意）',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
          // ⚠ **client で止める (#1012)。**超えるとサーバーが 400 / 422 で断り、
          // 画面には「通報に失敗しました」しか出ないので、理由も分からず書いた
          // 文章も失われる。上限の根拠は [InputLimits.reportComment]。
          maxLength: InputLimits.reportComment,
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('通報'),
      ),
    ],
  );
}
