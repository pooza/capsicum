import 'package:capsicum_core/capsicum_core.dart';

/// 返信の投稿画面を開くときの extra (#1380)。
///
/// 返信の入口（投稿のメニュー・操作の列・詳細の画面）は**これを通す**。判定を
/// 入口ごとに写さない。
///
/// [outer] はタイムラインに並んでいる行（リノートなら外側）、[target] は返信先
/// （リノートなら中身）。
Map<String, dynamic> replyComposeExtra({
  required Post outer,
  required Post target,
}) => {
  'replyTo': target,
  'replyLeavesChannel': ?replyLeavesChannel(outer: outer, target: target),
};

/// 返信がチャンネルの外に出るなら、そのチャンネルの名前（不明なら空文字）。
/// 出ないなら null (#1380)。
///
/// Misskey で、**チャンネルの外の投稿をチャンネルへリノートしたもの**から返信すると、
/// 返信先はリノートの中身になり、中身にチャンネルが無いので**返信はチャンネルの外に
/// 出る**（サーバーが返信先のチャンネルに合わせ直す・本文の無いリノートへは返信
/// できない）。capsicum からは変えられないので、送る前に分かるようにする。
///
/// ⚠ 出すのは「外側（押した場所）にチャンネルがあり、返信先に無い」ときだけ。
/// チャンネルの投稿そのものへの返信（チャンネルに入る）では出さない。
String? replyLeavesChannel({required Post outer, required Post target}) {
  if (outer.reblog == null) return null;
  if (outer.channelId == null || target.channelId != null) return null;
  return outer.channelName ?? '';
}

/// 投稿画面に出す注意書き (#1380)。[channelName] が空ならチャンネル名を出さない。
String replyLeavesChannelMessage(String channelName) {
  final where = channelName.isEmpty ? 'チャンネル' : 'チャンネル「$channelName」';
  return 'この返信は$whereの外に投稿されます。'
      'リノートの元の投稿がチャンネルの外にあるためです。';
}
