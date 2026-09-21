import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants.dart';
import '../platform/platform_info.dart';
import 'secret_service_probe.dart';
import 'secure_storage_health.dart';

/// secure storage へ触る**唯一の入口** (#1136)。
///
/// ## ⚠⚠ なぜクラスとして切り出すのか（「呼ぶ側が思い出す」をやめる）
///
/// [#1117](https://github.com/pooza/capsicum/issues/1117)-C は、応答しない
/// キーリングに触って**描くスレッドごと止まる**のを防ぐ関所（疎通確認 + 上限）を
/// 入れた。⚠⚠ **ところが関所を `AccountStorage` の private メソッドとして置いた
/// ので、同じ資源を触る他の 2 クラスには掛からなかった** —— `PushKeyStore` と
/// `DeviceInstallId` は `FlutterSecureStorage` を**自前で持って直に叩いて**おり、
/// [SecretServiceProbe] の参照が**ゼロ**だった (#1136)。
///
/// 実際にアカウント削除の裏で `PushKeyStore.delete` が走り、**画面が固まった**
/// （2026-09-13・Linux 機での実測）。`AccountStorage` 側のログは「関所が効いた」
/// と言っているのに、その隣で未ガードの delete がプラットフォームスレッドを
/// 塞いでいた。
///
/// ⚠⚠ **これは [#1113](https://github.com/pooza/capsicum/issues/1113) の
/// 「ガードは層ごとに抜ける」の再発。**関所を 1 クラスの中に置くと、
/// **4 つ目の呼び出し側が足されたときに同じことが起きる**。だから
/// **`FlutterSecureStorage` を持ってよいのはこのクラスだけ**にして、
/// `secure_storage_gate_guard_test` がソース走査でそれを固定している。
///
/// ## 何を統一して、何を統一しないか
///
/// - **統一する**: 触る前の疎通確認・待ちの上限・「触って固まった」の記録
/// - ⚠ **統一しない**: `IOSOptions` / `MacOsOptions`（accessibility・groupId）。
///   これは**保存先の区画そのもの**で、店ごとに違う（`PushKeyStore` は NSE と
///   共有する access group + `first_unlock`、`DeviceInstallId` は
///   `first_unlock_this_device`、`AccountStorage` は group 無しの
///   `first_unlock`）。⚠⚠ **揃えると既存 item が見えなくなる / 消せなくなる**
///   （#643 / #656 / #392 が実際に踏んだ -25299 と「旧 item が列挙できない」）。
///   だから options は各店が持つ [FlutterSecureStorage] のまま、**関所だけ**を
///   共有する。
///
/// ## ⚠ 上限は Secret Service のときだけ
///
/// Apple の Keychain / Android の Keystore / Windows の DPAPI は D-Bus を
/// 経由しないので**固まる形にならず**、代わりに**ローエンド機の初回初期化で
/// 数秒かかる**ことがある。全 OS に掛けると、遅いだけの端末でアカウントが
/// オフラインに落ち、「キーリング / Secret Service」を名指しする案内まで出て
/// いた（v1.64 のリリース前レビュー）。判定は [usesSecretService]。
class SecureStorageGate {
  /// [storage] は**この店の区画**を表す。options 込みで渡すこと。
  const SecureStorageGate(this._storage);

  final FlutterSecureStorage _storage;

  /// 読み取り。応答しなければ [TimeoutException] を投げる。
  ///
  /// ⚠ **null を返さない。**「読めなかった」を「無かった」に潰すと、
  /// **ログアウト扱い**になる経路がある（#959 / #1085）。区別は呼び出し側の仕事。
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _guard(
    kSecureStorageReadTimeout,
    'read',
    () => _storage.read(key: key, iOptions: iOptions, mOptions: mOptions),
  );

  /// 存在確認。読み取りと同じ上限を使う。
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _guard(
    kSecureStorageReadTimeout,
    'containsKey',
    () =>
        _storage.containsKey(key: key, iOptions: iOptions, mOptions: mOptions),
  );

  /// 全件列挙。⚠ **accessibility の焼き直し (#643 / #392) 専用**で、
  /// 通常経路では使わない（件数ぶんの往復になる）。
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _guard(
    kSecureStorageReadTimeout,
    'readAll',
    () => _storage.readAll(iOptions: iOptions, mOptions: mOptions),
  );

  /// 書き込み。⚠ **投げる側に倒す** —— 黙って落とすと「ログインできたのに
  /// トークンが無い」を作る (#1117-C)。
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _guard(
    kSecureStorageWriteTimeout,
    'write',
    () => _storage.write(
      key: key,
      value: value,
      iOptions: iOptions,
      mOptions: mOptions,
    ),
  );

  /// 削除。書き込みと同じ上限。握るかどうかは呼び出し側が決める
  /// （掃除の経路は握って観測へ回す・[AccountStorage] の delete が実例）。
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _guard(
    kSecureStorageWriteTimeout,
    'delete',
    () => _storage.delete(key: key, iOptions: iOptions, mOptions: mOptions),
  );

  /// 触る前に聞き、触ったら上限を掛ける。
  ///
  /// ⚠⚠ **順序が逆だと意味が無い (#1085)。**`flutter_secure_storage_linux` は
  /// メソッドチャネルのハンドラの中で `secret_password_*_sync` を直に呼ぶ。
  /// ハンドラが走るのは**プラットフォームスレッド**＝ GTK のメインループ＝
  /// **フレームを提示するスレッド**なので、そこが止まると
  /// **[Duration] の上限が発火しても旗を立てる相手が居ない**（画面は固まったまま）。
  /// 先に [SecretServiceProbe]（純 Dart の D-Bus）で聞いて、**触らずに諦める**。
  Future<T> _guard<T>(
    Duration limit,
    String operation,
    Future<T> Function() body,
  ) async {
    if (!await SecretServiceProbe.isResponsive()) {
      // ⚠ message で「触っていない」ことを伝える（Sentry で実タイムアウトと
      // 区別するため・[SecureStorageHealth.probeSkipMessage]）。
      throw TimeoutException(SecureStorageHealth.probeSkipMessage);
    }
    if (!usesSecretService) return body();
    return body().timeout(
      limit,
      onTimeout: () {
        // ⚠⚠ **触って固まったことを覚える (#1117-C)。**確認は true だったのに
        // 実際の呼び出しが固まった、という窓が実在する。覚えないと**後続の
        // アカウントが 1 件ごとに上限を払う**（10 件で 50 秒）。
        SecretServiceProbe.markUnresponsive();
        throw TimeoutException('secure storage $operation timed out', limit);
      },
    );
  }
}

/// 待ちの打ち切りを [SecureStorageHealth] へ記録する関所 (#1144)。
///
/// ⚠⚠ **`AccountStorage` 以外の店の打ち切りが、案内カードにも Sentry にも
/// 出ていなかった。**`PushKeyStore` / `DeviceInstallId` は関所を通るように
/// なった（#1136）が記録はしておらず、#1136 が実測した「アカウント削除の裏で
/// `PushKeyStore.delete` が固まる」経路のタイムアウトが、どこにも残らなかった。
///
/// ⚠ **呼ぶ側に思い出させない**（#1136 と同じ理由）。店がこの関所を持てば、
/// どの操作の打ち切りも記録される。`AccountStorage` は打ち切りに合わせて別の
/// 処理（オフライン保持への切り替え等）をするので、自分で記録する素の関所の
/// ままにしている。
class ReportingSecureStorageGate extends SecureStorageGate {
  const ReportingSecureStorageGate(super.storage, {required this.phase});

  /// Sentry の `phase` タグ（どの店の処理か）。
  final String phase;

  Future<T> _report<T>(Future<T> operation) async {
    try {
      return await operation;
    } on TimeoutException catch (e) {
      SecureStorageHealth.markUnavailable(e, phase: phase);
      rethrow;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _report(super.read(key: key, iOptions: iOptions, mOptions: mOptions));

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _report(
    super.containsKey(key: key, iOptions: iOptions, mOptions: mOptions),
  );

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _report(super.readAll(iOptions: iOptions, mOptions: mOptions));

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _report(
    super.write(key: key, value: value, iOptions: iOptions, mOptions: mOptions),
  );

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    MacOsOptions? mOptions,
  }) => _report(super.delete(key: key, iOptions: iOptions, mOptions: mOptions));
}
