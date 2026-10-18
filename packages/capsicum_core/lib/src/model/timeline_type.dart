/// タイムラインの種類。
///
/// ⚠ 保存は `name` で行う（タブ設定・デッキのカラム）。**並びを入れ替えても
/// 保存は壊れない**が、名前は変えないこと。
///
/// - [remote]: リモートのみの連合 TL（Mastodon の `public?remote=true`・#1278）。
///   Misskey には無い。
enum TimelineType { home, local, social, federated, remote, directMessages }
