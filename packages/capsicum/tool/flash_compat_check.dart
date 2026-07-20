/// Misskey Flash 互換確認ハーネス (#830)
///
/// プリセットサーバーで公開されている Flash を取得し、capsicum が使う
/// AiScript 評価器（pooza/aiscript-dart フォーク）でパース・実行できるかを
/// 実測する。Misskey の bump 時と、フォークの ref を上げたときに回す。
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
/// ## スコープ
///
/// **プリセットサーバー以外の Flash は対象外**（明示的な方針。#830）。
/// capsicum が動作を保証するのはプリセットサーバーの利用者に対してであり、
/// 未知のサーバーの Flash まで互換性を追う意図はない。
///
/// また母数は各サーバーの **featured Flash のみ**。全 Flash を列挙できる
/// 未認証 API は存在しない（`/api/flash/my` は認証必須、`/api/flash/search`
/// はクエリ必須）ため、「全部通った」は「featured が全部通った」の意。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aiscript/aiscript.dart';

/// 検体の取得元。プリセットサーバー（lib/src/preset_servers.dart）のうち
/// Misskey のもの。プリセットに Misskey サーバーが増えたらここにも足す。
const _hosts = <String, String>{
  'misskey.delmulin.com': 'ダイスキー',
  'mk.precure.fun': 'きゅあすきー',
};

/// 失敗の分類。そのまま次のアクションに対応する。
enum _Failure {
  /// AiScript の言語側が前進した → フォーク (pooza/aiscript-dart) の追従が必要
  parse('パース失敗', 'フォークの追従が必要'),

  /// ホスト供給変数が増えた → capsicum 側で供給を足す
  hostVar('ホスト供給変数の不足', 'capsicum 側で変数の供給を足す'),

  /// 標準ライブラリが増えた → バインディング層に足す
  stdlib('Ui: / Mk: の不足', 'バインディング層に実装を足す'),

  /// それ以外の実行時エラー → 評価器の非互換の可能性
  runtime('実行時エラー', '評価器の非互換を個別に調査');

  const _Failure(this.label, this.action);

  final String label;
  final String action;
}

class _Result {
  _Result.ok(this.server, this.title, this.components)
    : failure = null,
      detail = null;

  _Result.ng(this.server, this.title, this.failure, this.detail)
    : components = const {};

  final String server;
  final String title;
  final _Failure? failure;
  final String? detail;
  final Set<String> components;

  bool get isOk => failure == null;
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

/// Flash 実行環境のスタブ。Flutter widget は作らず、呼ばれた事実だけ記録する。
/// ここで «未定義» になったものが、そのままバインディング層の TODO になる。
Map<String, Value> _env({
  required String host,
  required String flashId,
  required List<Value> customEmojis,
  required Set<String> usedComponents,
  required Map<String, ObjValue> components,
}) {
  ObjValue component(String type, FnArgs args) {
    usedComponents.add(type);
    final opts = args.isNotEmpty ? args.check<ObjValue>(0) : ObjValue({});
    final id = args.length > 1
        ? args.check<StrValue>(1).value
        : 'c${components.length}';
    final v = ObjValue({
      'id': StrValue(id),
      'type': StrValue(type),
      'props': opts,
      'update': NativeFnValue((_, _) async => NullValue()),
    });
    components[id] = v;
    return v;
  }

  return {
    // --- ホストが供給する変数 ---
    'THIS_ID': StrValue(flashId),
    'THIS_URL': StrValue('https://$host/play/$flashId'),
    'USER_ID': StrValue('compat-check'),
    'USER_NAME': StrValue('compat-check'),
    'USER_USERNAME': StrValue('compat-check'),
    'CURRENT_URL': StrValue('https://$host/play/$flashId'),
    'SERVER_URL': StrValue('https://$host'),
    'LOCALE': StrValue('ja-JP'),
    'CUSTOM_EMOJIS': ArrValue(customEmojis),

    // --- Ui: 標準ライブラリ ---
    'Ui:render': NativeFnValue((_, _) async => NullValue()),
    'Ui:get': NativeFnValue((args, _) async {
      return components[args.check<StrValue>(0).value] ?? NullValue();
    }),
    'Ui:root': ObjValue({'update': NativeFnValue((_, _) async => NullValue())}),
    for (final t in const [
      'container',
      'text',
      'mfm',
      'textarea',
      'button',
      'buttons',
      'switch',
      'textInput',
      'numberInput',
      'select',
      'image',
      'folder',
      'postForm',
      'postFormButton',
    ])
      'Ui:C:$t': NativeFnValue((args, _) async => component(t, args)),

    // --- Mk: (API) ---
    'Mk:api': NativeFnValue((_, _) async => ObjValue({})),
    'Mk:dialog': NativeFnValue((_, _) async => NullValue()),
    'Mk:confirm': NativeFnValue((_, _) async => BoolValue(true)),
    'Mk:save': NativeFnValue((_, _) async => NullValue()),
    'Mk:load': NativeFnValue((_, _) async => NullValue()),
    'Mk:url': NativeFnValue((_, _) async => StrValue('https://$host/')),
    'Mk:nyaize': NativeFnValue((args, _) async => args.check<StrValue>(0)),
  };
}

Future<List<_Result>> _checkServer(String host, String label) async {
  stdout.writeln('=== $label ($host)');

  final emojis = <Value>[
    for (final e in ((await _post(host, '/api/emojis', {}))['emojis'] as List))
      ObjValue({
        'name': StrValue(e['name'] as String),
        'category': e['category'] == null
            ? NullValue()
            : StrValue(e['category'] as String),
        'aliases': ArrValue([]),
        'url': StrValue((e['url'] as String?) ?? ''),
      }),
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
    final script = (flash['script'] as String?) ?? '';
    final id = (flash['id'] as String?) ?? '';

    final ParseResult parsed;
    try {
      parsed = Parser().parse(script);
    } on AiScriptError catch (e) {
      results.add(_Result.ng(label, title, _Failure.parse, e.toString()));
      continue;
    }

    final used = <String>{};
    final components = <String, ObjValue>{};
    try {
      final state = Interpreter(
        _env(
          host: host,
          flashId: id,
          customEmojis: emojis,
          usedComponents: used,
          components: components,
        ),
      );
      state.source = parsed.source;
      await state.exec(parsed.ast);
      results.add(_Result.ok(label, title, used));
    } on RuntimeError catch (e) {
      // 未定義変数は RuntimeError に包まれて飛んでくるので、cause から
      // 元の例外を取り出して分類する（フォーク側で cause を保持させている）。
      final cause = e.cause;
      if (cause is NoSuchVariableException) {
        final isStdlib =
            cause.key.startsWith('Ui:') || cause.key.startsWith('Mk:');
        results.add(
          _Result.ng(
            label,
            title,
            isStdlib ? _Failure.stdlib : _Failure.hostVar,
            cause.key,
          ),
        );
      } else {
        results.add(_Result.ng(label, title, _Failure.runtime, e.toString()));
      }
    } catch (e) {
      results.add(_Result.ng(label, title, _Failure.runtime, e.toString()));
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
      stdout.writeln('     ${r.failure!.label}: ${r.detail}');
      stdout.writeln('     → ${r.failure!.action}');
    }
  }

  final ok = results.where((r) => r.isOk).length;
  final usedComponents = <String>{for (final r in results) ...r.components};

  stdout.writeln();
  stdout.writeln(
    '=== $ok / ${results.length} pass'
    '（母数は featured のみ・プリセット以外は対象外）',
  );
  if (usedComponents.isNotEmpty) {
    final sorted = usedComponents.toList()..sort();
    stdout.writeln('=== 実際に使われた Ui:C:* — ${sorted.join(' / ')}');
  }

  if (ok != results.length) exitCode = 1;
  return exitCode;
}
