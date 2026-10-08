import 'package:flutter/foundation.dart';

/// capsicum 運営元（自前サーバー）。ログイン画面のプリセット一覧と、
/// プッシュ通知の登録対象判定に共通して参照される。
class PresetServer {
  final String host;
  final String displayName;
  final bool isStaging;

  const PresetServer({
    required this.host,
    required this.displayName,
    this.isStaging = false,
  });
}

const List<PresetServer> kPresetServers = [
  PresetServer(host: 'mstdn.b-shock.org', displayName: '美食丼'),
  PresetServer(host: 'precure.ml', displayName: 'キュアスタ！'),
  PresetServer(host: 'mk.precure.fun', displayName: 'きゅあすきー'),
  PresetServer(host: 'mstdn.delmulin.com', displayName: 'デルムリン丼'),
  PresetServer(host: 'misskey.delmulin.com', displayName: 'ダイスキー'),
  // ステージング（デバッグビルドでのみ UI に出す。プッシュ登録判定は
  // ビルドに関わらず通す）。
  PresetServer(
    host: 'st2.mstdn.b-shock.org',
    displayName: '美食丼 (stg)',
    isStaging: true,
  ),
  PresetServer(
    host: 'st3.mstdn.delmulin.com',
    displayName: 'デルムリン丼 (stg)',
    isStaging: true,
  ),
  PresetServer(
    host: 'st2.precure.ml',
    displayName: 'キュアスタ！ (stg)',
    isStaging: true,
  ),
  PresetServer(
    host: 'st2.misskey.delmulin.com',
    displayName: 'ダイスキー (stg)',
    isStaging: true,
  ),
];

/// UI に表示するプリセット一覧。リリースビルドではステージングを除外する。
List<PresetServer> visiblePresetServers() => kPresetServers
    .where((s) => !s.isStaging || kDebugMode)
    .toList(growable: false);

/// プッシュ通知の登録適格ホスト集合。ステージングも含める（テスト端末で
/// ステージングアカウントを使っている場合に push が機能するように）。
final Set<String> kPresetServerHosts = kPresetServers
    .map((s) => s.host)
    .toSet();

/// 「プリセットの利用者」に数えないアカウント名 (2026-10-08 pooza)。
///
/// プリセットサーバーの `@test` は動作確認用のアカウントで、**これしか入って
/// いない端末は、プリセットを持たない人と同じ画面になる**（利用権の購入ボタンが
/// 出る）。⚠⚠ **購入の導線を見られる環境が、ほかに作れない** —— 運営者が
/// 持てるサーバーはステージングを含めてすべてプリセットで、ストアの審査担当へ
/// 渡せるのもプリセットのアカウントだけ。
///
/// ⚠ **通知の配送は変わらない。**relay はホストで通すので、`@test` にも無償で
/// 届く。変わるのは「課金の話を出すか」の側だけ。
/// ⚠ ほかのプリセットのアカウントが 1 つでも入っていれば、従来どおり
/// プリセットの利用者（[hasPresetAccountIn]）。
const kPresetExemptUsername = 'test';
