import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_gate.dart';

/// relay が発行した有償リレーの利用権トークン (#597 / #1121)。
///
/// ⚠⚠ **これは「購入した証拠」ではない。** `POST /entitlements` の認証は共有
/// シークレット 1 本で、**そのシークレットはバイナリから取り出せる**ので、
/// 誰でも `status: unverified` の行を作れる。**有効かどうかを決めるのは relay
/// 側**（レシート検証・capsicum-relay#61 / #62）で、**クライアントは判定しない**。
///
/// ⚠ **アカウントではなく購入に紐づく。** capsicum は元々マルチアカウントで、
/// 1 つの購入に複数の fedi アカウントがぶら下がる。**アカウントごとに持たない。**
@immutable
class EntitlementToken {
  const EntitlementToken({
    required this.token,
    required this.store,
    this.purchaseId,
    this.productId,
    this.status,
    this.expiresAt,
    this.environment,
  });

  /// `/register` に載せる値。⚠ **これ自体が capability なのでログに出さない。**
  final String token;

  /// `apple` / `google` / `microsoft`。
  final String store;

  /// ストアの購入識別子。⚠ **ログに出さない**（ストアの購入を名指しできる）。
  final String? purchaseId;
  final String? productId;

  /// relay 側の判定（`unverified` / `active` / `grace` / `expired` …）。
  /// ⚠ **表示に使うだけで、これを見て登録を止めない**（判定は relay の仕事）。
  final String? status;
  final String? expiresAt;
  final String? environment;

  /// `POST /entitlements` の応答から作る。[token] が空なら null。
  static EntitlementToken? fromRelay(Map<String, dynamic>? json) {
    final token = json?['token']?.toString() ?? '';
    if (token.isEmpty) return null;
    return EntitlementToken(
      token: token,
      store: json!['store']?.toString() ?? '',
      purchaseId: json['purchase_id']?.toString(),
      productId: json['product_id']?.toString(),
      status: json['status']?.toString(),
      expiresAt: json['expires_at']?.toString(),
      environment: json['environment']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'store': store,
    'purchase_id': ?purchaseId,
    'product_id': ?productId,
    'status': ?status,
    'expires_at': ?expiresAt,
    'environment': ?environment,
  };

  @override
  String toString() =>
      'EntitlementToken(store: $store, product: $productId, status: $status)';
}

/// [EntitlementToken] の保管 (#1121)。
///
/// ⚠ **secure storage に置く。**アクセストークンと同じ扱い。
///
/// ⚠ **NSE と共有しない**ので access group は付けない（復号に使わない）。
/// 区画は [AccountStorage] と同じ `first_unlock` —— 起動直後の登録が
/// デバイスロック中でも読めないと、**ロック中に届いた通知のための再登録が
/// 静かに失敗する**。
class EntitlementTokenStore {
  const EntitlementTokenStore._();

  static const _key = 'entitlement_token_v1';

  static const _gate = ReportingSecureStorageGate(
    FlutterSecureStorage(
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
      mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
      aOptions: kSecureStorageAndroidOptions,
    ),
    phase: 'entitlement',
  );

  /// ⚠ **プロセス内キャッシュ。**[load] は push 登録のたび（アカウントごと）に
  /// 呼ばれるので、毎回 secure storage を開くと起動時の登録が遅くなる。
  /// ⚠ Windows の `flutter_secure_storage` は単一ファイルを read-modify-write
  /// するので、**読みを減らすこと自体に意味がある**（#474）。
  ///
  /// ⚠⚠ **書き換えるのは [save] / [clear] だけ**なので、古い値が残ることはない。
  /// ⚠ **入るのは読めた結果だけ**（読めなかった回は確定させない・[load]）。
  static EntitlementToken? _cached;
  static bool _loaded = false;

  /// 保持している利用権トークン。無ければ null。
  ///
  /// ⚠ **読めなくても例外を投げない。**キーリングが停止している Linux 等で
  /// **push 登録そのものを道連れにしない**（#1117 / #1136）。持っていない扱いに
  /// 倒すと、非プリセットの購入者は従来どおり登録されないだけで済む。
  ///
  /// 🔴 **読めなかった結果をキャッシュしない。**以前は失敗も `_loaded = true` で
  /// 確定させていたので、**1 度読めないだけで、プロセスが終わるまで「持って
  /// いない」ことになった** —— 購入済みの人に購入ボタンが出て、登録にも
  /// トークンが載らない（リリース前レビューの Codex P1・2026-10-06）。
  /// 読めなかった回は確定させず、**次に呼ばれたときにもう一度読む**。
  ///
  /// ⚠ **「読めない」と「持っていない」を区別したい側は [loadOrThrow] を使う**
  /// （購入の画面。買った人に買わせないため）。こちらは登録の経路用。
  static Future<EntitlementToken?> load() async {
    try {
      return await loadOrThrow();
    } catch (e) {
      debugPrint('capsicum: entitlement: load failed (${e.runtimeType})');
      return null;
    }
  }

  /// [load] と同じだが、**読めなかったときは例外を投げる。**
  ///
  /// ⚠⚠ **購入の画面はこちらを使う。**null を「持っていない」と読むと、
  /// キーホルダが一時的に読めないだけで**購入済みの人に購入ボタンを出す**。
  /// 呼び出し側は例外を「分からない」として扱い、**未購入へ倒さない**。
  ///
  /// ## 読みと書き換えの順序 (#1247)
  ///
  /// 読みは**待ち行列の外**で走る。⚠ 行列に通さないのは意図どおり —— 通すと、
  /// **詰まった読みが購入直後の保存まで止める**（保存は読みが返るまで始まらない）。
  ///
  /// 代わりに、**読みが返ったあとの合流点を 1 か所だけ置く**。読んでいる間に
  /// [save] / [clear] が済んでいたら、そちらが新しいので、読んだ結果は
  /// **成功でも失敗でも**使わずキャッシュを返す。
  ///
  /// 🔴 以前はこの判定を結果ごとに書いていた（成功のあと・失敗の catch の中）。
  /// 片方にしか無かった時期があり、リリース PR の締めに 2 巡続けて穴が見つかった:
  /// - 成功の側に無い → 古い中身でキャッシュを上書きし、買った直後の token が
  ///   消える / 消した token が戻る
  /// - 失敗の側に無い → 済んだ保存を捨てて投げ、[load] が null に倒して、
  ///   買った直後の登録に token が載らない
  ///
  /// ⚠⚠ **読みの出口を増やすときも、必ず合流点を通す**（早期 return を足さない）。
  static Future<EntitlementToken?> loadOrThrow() async {
    if (_loaded) return _cached;

    String? raw;
    Object? failure;
    StackTrace? failureStack;
    try {
      raw = await _gate.read(key: _key);
    } catch (e, st) {
      failure = e;
      failureStack = st;
    }

    // ⚠⚠ **合流点。**書き換えは終わるときに `_loaded` を立てるので、それを見る。
    if (_loaded) return _cached;

    // ⚠ 読めなかった回は確定させない（次に呼ばれたときにもう一度読む）。
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    _cached = _decode(raw);
    _loaded = true;
    return _cached;
  }

  static Future<void> save(EntitlementToken token) {
    return _serialized(() async {
      await _gate.write(key: _key, value: jsonEncode(token.toJson()));
      _cached = token;
      _loaded = true;
    });
  }

  /// 書き換え（[save] / [clear]）の待ち行列の末尾。
  ///
  /// 🔴 **書き換えは、呼ばれた順に 1 本ずつ実行する**（リリース PR の Codex P1・
  /// 締めの回・2026-10-06）。読み直し・購入・記録の消去が別々にここを呼ぶので、
  /// 並べて走らせると**完了の順が呼んだ順と入れ替わりうる** —— 先に呼ばれた
  /// 古い値の保存が、あとから呼ばれた消去や新しい token の保存より遅れて終わると、
  /// **消した記録が戻る / 新しい token が古い値で上書きされる**。
  /// ⚠ 呼ぶ側の世代の検査（`EntitlementStatusNotifier`）は「これから書くか」を
  /// 止めるだけで、**もう書きはじめた 1 本は止められない**。順序はここで守る。
  static Future<void> _writes = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() body) {
    final run = _writes.then((_) => body());
    // ⚠ 失敗しても行列は止めない（次の書き換えを巻き込まない）。
    _writes = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// テストが待ち行列の順序を確かめるための口。
  @visibleForTesting
  static Future<T> serializedForTesting<T>(Future<T> Function() body) =>
      _serialized(body);

  /// 保存した利用権を消す。**消せたか**を返す。
  ///
  /// ⚠ 例外にはしない（呼び出し側が握り忘れても落ちない）が、**結果は必ず返す**。
  ///
  /// 🔴 **消せなかった回は、キャッシュを「消えた」にしない** (#1247)。以前は削除の
  /// 失敗を握ったうえでキャッシュを空に確定させていたので、画面は「消えた」と
  /// 伝えるのに、**再起動すると token が読み直されて戻っていた**。
  /// ⚠ 消去は利用者が押した操作なので、失敗は伝えてよい（読みの側の
  /// 「push 登録を道連れにしない」とは事情が違う）。
  static Future<bool> clear() {
    return _serialized(() async {
      try {
        await _gate.delete(key: _key);
      } catch (e) {
        debugPrint('capsicum: entitlement: clear failed (${e.runtimeType})');
        return false;
      }
      _cached = null;
      _loaded = true;
      return true;
    });
  }

  /// テストがプロセス内キャッシュを捨てるための口。
  @visibleForTesting
  static void resetCacheForTesting() {
    _cached = null;
    _loaded = false;
  }

  /// ⚠ **壊れた JSON で落ちない。**保存形式を変えたときに、古い値が読めない
  /// だけで起動が止まらないように。
  static EntitlementToken? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return EntitlementToken.fromRelay(json);
    } on FormatException {
      return null;
    }
  }
}
