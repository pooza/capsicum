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
  static Future<EntitlementToken?> loadOrThrow() async {
    if (_loaded) return _cached;

    final raw = await _gate.read(key: _key);
    _cached = _decode(raw);
    _loaded = true;
    return _cached;
  }

  static Future<void> save(EntitlementToken token) async {
    await _gate.write(key: _key, value: jsonEncode(token.toJson()));
    _cached = token;
    _loaded = true;
  }

  /// ⚠ 購入が無くなったときに消す。**消せなくても例外にしない**（load と同じ理由）。
  static Future<void> clear() async {
    try {
      await _gate.delete(key: _key);
    } catch (e) {
      debugPrint('capsicum: entitlement: clear failed (${e.runtimeType})');
    }
    _cached = null;
    _loaded = true;
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
