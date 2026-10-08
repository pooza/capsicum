import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../url_helper.dart';
import '../util/launch_url_toast.dart';

/// 段落の中の 1 語だけをリンクにする (#1221)。
///
/// ⚠⚠ **用語の説明へ辿る導線を、文字列ごと画面へ写さない。**「プリセット
/// サーバー」は有償リレーで**課金の線引きそのもの**になったため出てくる画面が
/// 増えた（プッシュ通知設定・サポーター画面・ログイン画面）。⚠ 同じ導線を画面
/// ごとに書くと、#1226 の「裸のリレー」と同じ形で**片方だけ直った状態**になる。
///
/// ⚠⚠ **光るのは最初の 1 回だけ。**同じ語が 2 回出る段落で全部光ると読めない
/// （#1221 の完了条件）。[term] が見つからなければ**ただの [Text] として描く**
/// ので、文面から語が消えても壊れない。
///
/// ⚠ **失敗を黙って捨てない。**外部ブラウザが開けなければ
/// [launchUrlOrToast] が SnackBar を出す（#976 の流儀）。⚠ ログイン画面は
/// [launchUrlSafely] の裸呼び出しのままだったので、#1221 でこちらへ寄せた。
///
/// ⚠ **`TapGestureRecognizer` は自分で捨てる。**`TextSpan` に渡した
/// recognizer は Flutter が破棄してくれないので [State] に持たせる
/// （`post_tile` が同じ理由で苦労している）。
class TermLinkText extends StatefulWidget {
  /// 段落の全文。
  final String text;

  /// この語の**最初の出現**をリンクにする。
  final String term;

  /// 開く先。
  final Uri url;

  final TextStyle? style;

  const TermLinkText({
    super.key,
    required this.text,
    required this.term,
    required this.url,
    this.style,
  });

  @override
  State<TermLinkText> createState() => _TermLinkTextState();
}

class _TermLinkTextState extends State<TermLinkText> {
  TapGestureRecognizer? _recognizer;

  @override
  void dispose() {
    _recognizer?.dispose();
    super.dispose();
  }

  void _open() {
    // ⚠ `mounted` を見る —— 起動の往復から戻るまでに画面を離れていることがある。
    if (!mounted) return;
    launchUrlOrToast(context, widget.url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.text.indexOf(widget.term);
    // ⚠ 語が無い文面でも描ける（状態で文面が差し替わる画面があるため）。
    if (index < 0) return Text(widget.text, style: widget.style);

    _recognizer ??= TapGestureRecognizer()..onTap = _open;
    final scheme = Theme.of(context).colorScheme;
    final after = index + widget.term.length;

    return Text.rich(
      TextSpan(
        children: [
          if (index > 0) TextSpan(text: widget.text.substring(0, index)),
          TextSpan(
            text: widget.term,
            style: TextStyle(
              color: scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary,
            ),
            recognizer: _recognizer,
          ),
          if (after < widget.text.length)
            TextSpan(text: widget.text.substring(after)),
        ],
      ),
      style: widget.style,
    );
  }
}
