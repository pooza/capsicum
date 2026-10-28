import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 送る直前の記録に、サーバーのソフトウェア名を `software` のタグで足す (#1337)。
///
/// ⚠ Mastodon の一種として動いているフォーク（Akkoma・Pleroma など）の失敗が、
/// `backend` のタグ（mastodon / misskey）だけだと本家の失敗に紛れて気付けない。
///
/// host のタグは記録を作る側がそれぞれ付けている（`host` / ストリーミングの
/// `stream.connect.host`）。⚠ 個々の箇所に足すと取りこぼすので、送る直前の
/// 1 か所（`beforeSend`）で、host のタグから引いて足す。名前は
/// [knownSoftwareName]（NodeInfo で読めたもの）。分からなければ足さない。
SentryEvent tagServerSoftware(SentryEvent event) {
  final tags = event.tags;
  if (tags == null || tags.containsKey(softwareTag)) return event;
  final host = tags['host'] ?? tags['stream.connect.host'];
  if (host == null || host.isEmpty || host == '-') return event;
  final software = knownSoftwareName(host);
  if (software == null) return event;
  event.tags = {...tags, softwareTag: software};
  return event;
}

const softwareTag = 'software';
