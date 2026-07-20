/// Misskey Flash（UI 表記は Play）互換確認ハーネス (#830)
///
/// プリセットサーバーで公開されている Flash を取得し、**capsicum が本番で使う
/// [FlashRuntime] そのもの**でパース・実行できるかを実測する。Misskey の
/// bump 時と、AiScript フォークの ref を上げたときに回す。
///
///     dart run tool/flash_compat_check.dart
///
/// ## なぜ必要か
///
/// docs/misskey-capsicum-api-watch.md の API 契約 diff（misskey-js の
/// autogen/entities.ts・endpoint.ts）は **AiScript の変化を検知できない**。
/// AiScript は API 契約ではないため、`@syuilo/aiscript` が上がって新構文が
/// 入っても autogen は 1 行も動かない。ここを埋めるための実測。
///
/// ## 本番コードを直接叩くこと
///
/// `Ui:` バインディングをこのファイルにスタブで持たせると、本番の
/// [FlashRuntime] と二重管理になり、片方だけ直したときに互換確認が嘘をつく。
/// そのため [FlashRuntime] は Flutter に依存させず、ここから素の `dart run`
/// で駆動できるようにしてある。**このハーネスに `Ui:` の実装を書かないこと。**
///
/// ## スコープ
///
/// **プリセットサーバー以外の Flash は対象外**（明示的な方針）。capsicum が
/// 動作を保証するのはプリセットサーバーの利用者に対してであり、未知の
/// サーバーの Flash まで互換性を追う意図はない。
///
/// また母数は各サーバーの **featured Flash のみ**。全 Flash を列挙できる
/// 未認証 API は存在しない（`flash/my` は認証必須、`flash/search` はクエリ
/// 必須）ため、「全部通った」は「featured が全部通った」の意。
library;

import 'dart:convert';
import 'dart:io';

import 'package:capsicum/src/ui/flash/flash_runtime.dart';

/// 検体の取得元。プリセットサーバー（lib/src/preset_servers.dart）のうち
/// Misskey のもの。プリセットに Misskey サーバーが増えたらここにも足す。
const _hosts = <String, String>{
  'misskey.delmulin.com': 'ダイスキー',
  'mk.precure.fun': 'きゅあすきー',
};

class _Result {
  _Result.ok(this.server, this.title, this.componentTypes) : error = null;

  _Result.ng(this.server, this.title, this.error)
    : componentTypes = const <String>{};

  final String server;
  final String title;
  final FlashRuntimeError? error;
  final Set<String> componentTypes;

  bool get isOk => error == null;
}

Future<dynamic> _post(
  String host,
  String path,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.https(host, path));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode} for $path', uri: req.uri);
    }
    return jsonDecode(await res.transform(utf8.decoder).join());
  } finally {
    client.close();
  }
}

/// 描画ツリーに実際に出てきたコンポーネント種別を集める。
/// バインディング層の必要スコープを可視化するのが目的。
Set<String> _collectTypes(FlashRuntime runtime) {
  final types = <String>{};
  final queue = <String>[...runtime.rootChildren];
  final seen = <String>{};
  while (queue.isNotEmpty) {
    final id = queue.removeLast();
    if (!seen.add(id)) continue;
    final component = runtime.component(id);
    if (component == null) continue;
    types.add(component.type);
    queue.addAll(component.children);
  }
  return types;
}

Future<List<_Result>> _checkServer(String host, String label) async {
  stdout.writeln('=== $label ($host)');

  final emojis = <({String name, String? category})>[
    for (final e in ((await _post(host, '/api/emojis', {}))['emojis'] as List))
      (name: e['name'] as String, category: e['category'] as String?),
  ];

  final flashes =
      (await _post(host, '/api/flash/featured', {'limit': 100}) as List)
          .cast<Map<String, dynamic>>();
  stdout.writeln(
    '  featured Flash: ${flashes.length} 本 / カスタム絵文字 ${emojis.length} 件',
  );

  final results = <_Result>[];
  for (final flash in flashes) {
    final title = (flash['title'] as String?) ?? '(無題)';
    final runtime = FlashRuntime(
      flashId: (flash['id'] as String?) ?? '',
      host: host,
      customEmojis: emojis,
      userId: 'compat-check',
      userName: 'compat-check',
      userUsername: 'compat-check',
    );
    try {
      await runtime.run((flash['script'] as String?) ?? '');
      results.add(_Result.ok(label, title, _collectTypes(runtime)));
    } on FlashRuntimeError catch (e) {
      results.add(_Result.ng(label, title, e));
    } finally {
      runtime.dispose();
    }
  }
  return results;
}

Future<int> main() async {
  final results = <_Result>[];
  for (final entry in _hosts.entries) {
    try {
      results.addAll(await _checkServer(entry.key, entry.value));
    } catch (e) {
      // 取得自体に失敗した場合は互換性の判定ができない。成功と混同させない。
      stderr.writeln('  取得失敗 (${entry.key}): $e');
      exitCode = 2;
    }
  }

  stdout.writeln();
  for (final r in results) {
    if (r.isOk) {
      stdout.writeln('OK   [${r.server}] ${r.title}');
    } else {
      stdout.writeln('NG   [${r.server}] ${r.title}');
      stdout.writeln('     ${r.error!.summary}');
      if (r.error!.detail.isNotEmpty) {
        stdout.writeln('     ${r.error!.detail}');
      }
    }
  }

  final ok = results.where((r) => r.isOk).length;
  final types = <String>{for (final r in results) ...r.componentTypes};

  stdout.writeln();
  stdout.writeln(
    '=== $ok / ${results.length} pass'
    '（母数は featured のみ・プリセット以外は対象外）',
  );
  if (types.isNotEmpty) {
    final sorted = types.toList()..sort();
    stdout.writeln('=== 実際に描画されたコンポーネント — ${sorted.join(' / ')}');
  }

  if (ok != results.length) exitCode = 1;
  return exitCode;
}
