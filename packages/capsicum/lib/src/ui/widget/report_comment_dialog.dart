import 'package:flutter/material.dart';

import '../../constants.dart';

/// 通報ダイアログの入力 (#1203)。
typedef ReportInput = ({String comment, bool forward});

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
Future<ReportInput?> showReportCommentDialog(
  BuildContext context, {
  required String message,
  String? forwardHost,
}) => showDialog<ReportInput>(
  context: context,
  builder: (_) =>
      _ReportCommentDialog(message: message, forwardHost: forwardHost),
);

class _ReportCommentDialog extends StatefulWidget {
  const _ReportCommentDialog({required this.message, this.forwardHost});

  final String message;
  final String? forwardHost;

  @override
  State<_ReportCommentDialog> createState() => _ReportCommentDialogState();
}

class _ReportCommentDialogState extends State<_ReportCommentDialog> {
  final _controller = TextEditingController();
  late bool _forward = widget.forwardHost != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final forwardHost = widget.forwardHost;
    return AlertDialog(
      title: const Text('通報'),
      // 小さい画面でキーボードが出ると、チェックのぶんだけ縦が足りなくなる。
      content: SingleChildScrollView(
        child: Column(
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
              // ⚠ **client で止める (#1012)。**超えるとサーバーが 400 / 422 で
              // 断り、画面には「通報に失敗しました」しか出ないので、理由も
              // 分からず書いた文章も失われる。上限の根拠は
              // [InputLimits.reportComment]。
              maxLength: InputLimits.reportComment,
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
          onPressed: () => Navigator.pop(context, (
            comment: _controller.text.trim(),
            forward: forwardHost != null && _forward,
          )),
          child: const Text('通報'),
        ),
      ],
    );
  }
}
