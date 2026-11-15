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

/// 返信が押した場所のチャンネルに入らないなら、その注意書き。入るなら null
/// (#1380)。
///
/// Misskey で、**チャンネルの外の投稿をチャンネルへリノートしたもの**から返信すると、
/// 返信先はリノートの中身になり、中身にチャンネルが無いので**返信はチャンネルの外に
/// 出る**（サーバーが返信先のチャンネルに合わせ直す・本文の無いリノートへは返信
/// できない）。capsicum からは変えられないので、送る前に分かるようにする。
///
/// ⚠ 出すのは「外側（押した場所）にチャンネルがあり、返信先のチャンネルが
/// それと違う」ときだけ。チャンネルの投稿そのものへの返信（チャンネルに入る）
/// では出さない。
/// ⚠ 返信先が**別のチャンネル**にあることもある（そのチャンネルが外への
/// リノートを許していれば、チャンネル A に B の投稿をリノートできる）。その
/// 返信は A ではなく B に入る（v2.12 のリリース前レビュー）。
///
/// 返すのは投稿画面に出す文面（[replyLeavesChannelMessage]）。出さないなら null。
String? replyLeavesChannel({required Post outer, required Post target}) {
  if (outer.reblog == null) return null;
  final from = outer.channelId;
  if (from == null || from == target.channelId) return null;
  return replyLeavesChannelMessage(
    from: outer.channelName ?? '',
    to: target.channelId == null ? null : (target.channelName ?? ''),
  );
}

/// 投稿画面に出す注意書き (#1380)。[from] は押した場所のチャンネル名、[to] は
/// 返信が入るチャンネル名（チャンネルの外なら null）。名前が空なら名前を出さない。
String replyLeavesChannelMessage({required String from, String? to}) {
  final where = from.isEmpty ? 'チャンネル' : 'チャンネル「$from」';
  if (to == null) {
    return 'この返信は$whereの外に投稿されます。'
        'リノートの元の投稿がチャンネルの外にあるためです。';
  }
  final there = to.isEmpty ? '別のチャンネル' : 'チャンネル「$to」';
  return 'この返信は$whereではなく、$thereに投稿されます。'
      'リノートの元の投稿が$thereにあるためです。';
}
