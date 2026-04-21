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
    host: 'st.mstdn.b-shock.org',
    displayName: '美食丼 (stg)',
    isStaging: true,
  ),
  PresetServer(
    host: 'st2.mstdn.delmulin.com',
    displayName: 'デルムリン丼 (stg)',
    isStaging: true,
  ),
  PresetServer(
    host: 'st.precure.ml',
    displayName: 'キュアスタ！ (stg)',
    isStaging: true,
  ),
  PresetServer(
    host: 'st.misskey.delmulin.com',
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
