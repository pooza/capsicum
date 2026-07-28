import 'package:aiscript/aiscript.dart';

import 'as_ui.dart';

/// Flash スクリプトの実行時エラー。UI にそのまま出せる日本語の要約を持つ。
class FlashRuntimeError implements Exception {
  FlashRuntimeError(
    this.summary,
    this.detail, {
    this.unimplementedKey,
    this.langUnsupported = false,
  });

  /// ユーザーに見せる 1 行要約。
  final String summary;

  /// 原因の詳細（評価器のメッセージ等）。
  final String detail;

  /// capsicum のバインディング層が未実装だった `Ui:C:*` / `Mk:*` キー。
  /// 機能別に Sentry で絞り込むためのタグ用 (#875)。未実装以外では null。
  final String? unimplementedKey;

  /// 新しい AiScript 宣言（1.0.0+）ゆえに評価せず degrade した「失敗ではない」
  /// エラーか (#881)。true のときは UI が「このまま実行する」導線を出せる
  /// （互換性を承知で従来どおりネイティブ実行させるための逃げ道）。
  final bool langUnsupported;

  @override
  String toString() => '$summary: $detail';
}

/// AiScript で書かれた Flash を実行し、`Ui:` 由来のコンポーネントツリーを
/// 保持するランタイム (#830)。
///
/// 本家の `pages/flash/flash.vue` + `aiscript/ui.ts` に相当する。評価器は
/// pooza/aiscript-dart フォーク。
///
/// スクリプトは `Ui:render(...)` を呼んだあとも、`Ui:get(id).update(...)` や
/// ボタンの `onClick` から**非同期にツリーを書き換える**。そのため変更を
/// リスナーへ通知し、ビュー側が追従する。
///
/// **このクラスは Flutter に依存させない。** `tool/flash_compat_check.dart`
/// が同じバインディング層を素の `dart run` で回せるようにするため。ここで
/// ChangeNotifier を使うと、ハーネス側に `Ui:` のスタブを別実装することに
/// なり、本番と互換確認が二重管理になって乖離する (#830)。
class FlashRuntime {
  FlashRuntime({
    required this.flashId,
    required this.host,
    required this.customEmojis,
    this.userId,
    this.userName,
    this.userUsername,
  });

  final String flashId;
  final String host;

  /// サーバーのカスタム絵文字。スクリプトが `CUSTOM_EMOJIS` で参照する。
  /// 実在の Flash（絵文字ガチャ系）が必須で使うため供給する。
  final List<({String name, String? category})> customEmojis;

  final String? userId;
  final String? userName;
  final String? userUsername;

  final Map<String, AsUiComponent> _components = {};
  final List<String> _rootChildren = [];

  Interpreter? _interpreter;
  bool _disposed = false;
  final List<void Function()> _listeners = [];

  /// ツリーが書き換わったときに呼ばれるリスナーを登録する。
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// スクリプトのコールバック（`onClick` 等）が投げた例外の通知先。
  /// 既定では握りつぶす（UI 全体を巻き込まないため）。
  void Function(Object error, StackTrace stackTrace)? onCallbackError;

  /// ルート直下に描画する子コンポーネントの id 配列。
  List<String> get rootChildren => List.unmodifiable(_rootChildren);

  AsUiComponent? component(String id) => _components[id];

  /// スクリプト先頭の `/// @<version>` 注釈から宣言 AiScript 言語バージョンを
  /// 取り出す。宣言が無ければ null。
  static String? scriptLangVersion(String script) =>
      Parser.getLangVersion(script);

  /// この Play を capsicum の評価器で実行すると本家と結果がズレうるか (#881)。
  ///
  /// 本家 Misskey は宣言バージョン 1.0.0 未満（および宣言なし）を legacy 実行系に
  /// 回しており、capsicum の評価器（pooza/aiscript-dart フォーク・0.16 相当）は
  /// その legacy 相当。1.0.0 以上を宣言する Play は 1.x で演算子の優先順位が
  /// 変わっている等の理由で **パースエラーにならず結果だけ変わる**（silent）
  /// おそれがあるため、評価せずブラウザ導線へ degrade する。
  ///
  /// 解釈できない宣言（想定外の書式）は従来どおり legacy 側に倒して実行する
  /// （正当な Play を誤ってブロックしないため。踏むのは silent 差異の可能性の
  /// ある新しめの Play に限る）。
  static bool isScriptLangUnsupported(String script) {
    final version = scriptLangVersion(script);
    if (version == null) return false;
    final major = int.tryParse(version.split('.').first);
    if (major == null) return false;
    return major >= 1;
  }

  /// スクリプトをパースして実行する。
  ///
  /// 失敗は [FlashRuntimeError] に正規化する。分類は
  /// `tool/flash_compat_check.dart` と揃えてあり、未定義変数が `Ui:` / `Mk:`
  /// で始まるかどうかで「capsicum 未実装」と「スクリプト側の問題」を分ける。
  Future<void> run(String script) async {
    if (script.isEmpty) {
      throw FlashRuntimeError('この Play にはスクリプトがありません', '');
    }

    final ParseResult parsed;
    try {
      parsed = Parser().parse(script);
    } on AiScriptError catch (e) {
      throw FlashRuntimeError('この Play を読み込めませんでした', e.toString());
    }

    final interpreter = Interpreter(_buildEnv());
    interpreter.source = parsed.source;
    _interpreter = interpreter;

    try {
      await interpreter.exec(parsed.ast);
    } on RuntimeError catch (e) {
      throw _mapRuntimeError(e);
    } on AiScriptError catch (e) {
      throw FlashRuntimeError('この Play の実行でエラーが起きました', e.toString());
    }
    _notify();
  }

  FlashRuntimeError _mapRuntimeError(RuntimeError e) {
    final cause = e.cause;
    if (cause is NoSuchVariableException) {
      final key = cause.key;
      if (key.startsWith('Ui:') || key.startsWith('Mk:')) {
        // capsicum のバインディング層が未実装。スクリプトの不具合ではない
        // ので、そう分かる文言にする。
        return FlashRuntimeError(
          'この Play が使う機能に capsicum が未対応です',
          '未実装: $key',
          unimplementedKey: key,
        );
      }
    }
    return FlashRuntimeError('この Play の実行でエラーが起きました', e.toString());
  }

  void _notify() {
    if (_disposed) return;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
    // 実行中のスクリプト（Async:interval 等）を止める。止めないと画面を
    // 閉じたあとも評価が回り続ける。
    _interpreter?.abort();
    _interpreter = null;
  }

  // --- 値変換 ---

  /// 評価器の値を Dart の素の値へ落とす。関数値は呼び出しのために
  /// [FnValue] のまま保持する。
  Object? _toDart(Value? v) {
    if (v == null || v is NullValue) return null;
    if (v is StrValue) return v.value;
    if (v is NumValue) return v.value;
    if (v is BoolValue) return v.value;
    if (v is ArrValue) return v.value.map(_toDart).toList(growable: false);
    if (v is ObjValue) {
      return {for (final e in v.value.entries) e.key: _toDart(e.value)};
    }
    if (v is FnValue) return v;
    return null;
  }

  /// `Ui:C:*` の定義オブジェクトを props へ変換する。
  ///
  /// `children` は本家と同じく **子オブジェクトから id を抜いた文字列配列**に
  /// 正規化する。
  Map<String, Object?> _readProps(Value? def) {
    if (def is! ObjValue) return {};
    final props = <String, Object?>{};
    for (final entry in def.value.entries) {
      if (entry.key == 'children') {
        final raw = entry.value;
        props['children'] = raw is ArrValue
            ? [
                for (final child in raw.value)
                  if (child is ObjValue && child.value['id'] is StrValue)
                    (child.value['id']! as StrValue).value,
              ]
            : const <String>[];
        continue;
      }
      props[entry.key] = _toDart(entry.value);
    }
    return props;
  }

  /// `Ui:C:*` の戻り値（`{ id, update }`）を組み立てつつレジストリへ登録する。
  ObjValue _createComponent(String type, FnArgs args) {
    final def = args.isNotEmpty ? args.check<Value>(0) : null;
    final id = args.length > 1
        ? args.check<StrValue>(1).value
        : 'c${_components.length}';

    final component = AsUiComponent(id: id, type: type, props: _readProps(def));
    _components[id] = component;

    return ObjValue({
      'id': StrValue(id),
      'update': NativeFnValue((updateArgs, _) async {
        // 本家の update は def に存在するキーだけを上書きする。
        component.patch(_readProps(updateArgs.check<Value>(0)));
        _notify();
        return NullValue();
      }),
    });
  }

  Map<String, Value> _buildEnv() {
    ObjValue componentFactory(String type, FnArgs args) =>
        _createComponent(type, args);

    return {
      // --- ホストが供給する変数 ---
      'THIS_ID': StrValue(flashId),
      'THIS_URL': StrValue('https://$host/play/$flashId'),
      'CURRENT_URL': StrValue('https://$host/play/$flashId'),
      'SERVER_URL': StrValue('https://$host'),
      'LOCALE': StrValue('ja-JP'),
      'USER_ID': userId == null ? NullValue() : StrValue(userId!),
      'USER_NAME': userName == null ? NullValue() : StrValue(userName!),
      'USER_USERNAME': userUsername == null
          ? NullValue()
          : StrValue(userUsername!),
      'CUSTOM_EMOJIS': ArrValue([
        for (final e in customEmojis)
          ObjValue({
            'name': StrValue(e.name),
            'category': e.category == null
                ? NullValue()
                : StrValue(e.category!),
            'aliases': ArrValue([]),
            'url': StrValue('https://$host/emoji/${e.name}.webp'),
          }),
      ]),

      // --- Ui: ---
      'Ui:render': NativeFnValue((args, _) async {
        final children = args.check<ArrValue>(0);
        _rootChildren
          ..clear()
          ..addAll([
            for (final child in children.value)
              if (child is ObjValue && child.value['id'] is StrValue)
                (child.value['id']! as StrValue).value,
          ]);
        _notify();
        return NullValue();
      }),
      'Ui:get': NativeFnValue((args, _) async {
        final id = args.check<StrValue>(0).value;
        final component = _components[id];
        if (component == null) return NullValue();
        return ObjValue({
          'id': StrValue(id),
          'update': NativeFnValue((updateArgs, _) async {
            component.patch(_readProps(updateArgs.check<Value>(0)));
            _notify();
            return NullValue();
          }),
        });
      }),
      for (final type in kSupportedAsUiTypes)
        'Ui:C:$type': NativeFnValue(
          (args, _) async => componentFactory(type, args),
        ),
    };
  }

  /// 呼び出し可能な AiScript 関数（`onClick` 等）を実行する。
  ///
  /// ボタン押下のたびにここを通す。スクリプト側で例外が出ても UI を巻き込ま
  /// ないように握りつぶし、debug ビルドでのみ表面化させる。
  Future<void> invoke(Object? fn) async {
    final interpreter = _interpreter;
    if (fn is! FnValue || interpreter == null || _disposed) return;
    try {
      await interpreter.call(fn);
    } catch (e, stackTrace) {
      onCallbackError?.call(e, stackTrace);
    }
    _notify();
  }
}

/// バインディング層が widget を持っているコンポーネント種別 (#830)。
///
/// ここに無い `Ui:C:*` は未定義変数として実行時に落ち、
/// [FlashRuntime._mapRuntimeError] が「capsicum が未対応」に分類する。
/// 黙って無視すると、描画されない理由がユーザーにもログにも残らないため、
/// あえて束縛しない。
const kSupportedAsUiTypes = {
  'container',
  'text',
  'mfm',
  'button',
  'buttons',
  'postFormButton',
};
