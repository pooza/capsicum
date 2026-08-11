import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../provider/preferences_provider.dart';
import '../../../service/sentry_op_failure.dart';
import '../../../service/settings_backup.dart';

/// 設定のバックアップ (#857)。
///
/// アカウント・認証情報は含まない（理由は [settings_backup.dart] の doc）。
/// モバイルはメディア以外のファイルを保存する手段が限られるため、当面
/// デスクトップのみに出す（導線側で `isDesktop` ゲート）。
class SettingsBackupScreen extends ConsumerStatefulWidget {
  const SettingsBackupScreen({super.key});

  @override
  ConsumerState<SettingsBackupScreen> createState() =>
      _SettingsBackupScreenState();
}

class _SettingsBackupScreenState extends ConsumerState<SettingsBackupScreen> {
  bool _busy = false;

  static const _typeGroup = XTypeGroup(
    label: '設定のバックアップ',
    extensions: ['yaml', 'yml'],
  );

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final location = await getSaveLocation(
        suggestedName: 'capsicum-settings.yaml',
        acceptedTypeGroups: const [_typeGroup],
      );
      if (location == null) return; // キャンセル

      final prefs = await SharedPreferences.getInstance();
      final info = await PackageInfo.fromPlatform();
      final yaml = buildSettingsBackupYaml(
        prefs,
        appVersion: '${info.version}+${info.buildNumber}',
        exportedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await File(location.path).writeAsString(yaml);
      messenger.showSnackBar(const SnackBar(content: Text('設定を書き出しました')));
    } catch (e, st) {
      // 新規のファイル I/O 機能なので本番の失敗率（権限 / 容量等）を観測する
      // (#968)。reportOpFailure が scrubException を通すので、生 URL / トークンは
      // 載らない。バックアップはアカウント非依存なので host / backend は '-'。
      reportOpFailure(
        tagKey: 'settings_backup.op',
        operation: 'export',
        error: e,
        stackTrace: st,
      );
      messenger.showSnackBar(SnackBar(content: Text('書き出せませんでした: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    final file = await openFile(acceptedTypeGroups: const [_typeGroup]);
    if (file == null || !mounted) return; // キャンセル

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('設定を読み込む'),
        content: const Text('この端末の設定が、ファイルの内容で上書きされます。よろしいですか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('読み込む'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final text = await file.readAsString();
      final prefs = await SharedPreferences.getInstance();
      final result = await applySettingsBackupYaml(prefs, text);
      // ref を触る前に mounted を見る (#955)。読み込み中に画面を離れると
      // ref.invalidate が StateError を投げ、下の catch が「読み込めません
      // でした」と出す——**設定は書き込み済みなのに**失敗したように見える。
      if (!mounted) return;
      // 各 Notifier は build() で prefs を読み直すので、invalidate すれば
      // 画面が新しい設定で組み直される（再起動を求めない）。
      _refreshPreferenceProviders();
      _reportImportSkips(result);
      messenger.showSnackBar(SnackBar(content: Text(_importSummary(result))));
    } on SettingsBackupFormatException catch (e, st) {
      // 不正 YAML / 版違い / 設定ファイルでない、の失敗率を観測する (#968)。
      // **例外の message は Sentry に載せない**: 「読み込めませんでした: <yaml
      // エラー>」の yaml エラーにファイルの行断片（＝設定値）が混じりうるため、
      // 内容を含まない合成エラーで件数だけ数える。画面には従来どおり理由を出す
      // （ユーザー自身のファイルなので UI に出すのは問題ない）。fingerprint は
      // 下の汎用失敗と分ける。
      reportOpFailure(
        tagKey: 'settings_backup.op',
        operation: 'import',
        error: StateError('settings backup: unparseable / incompatible file'),
        stackTrace: st,
        tags: {'reason': 'format'},
      );
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e, st) {
      // 権限 / 容量 / 読み取り失敗など。IO 例外の toString はローカルパスを含む
      // が値は含まない。scrubException は通す。
      reportOpFailure(
        tagKey: 'settings_backup.op',
        operation: 'import',
        error: e,
        stackTrace: st,
      );
      messenger.showSnackBar(SnackBar(content: Text('読み込めませんでした: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 取り込まなかったキーの内訳を Sentry へ残す (#968)。
  ///
  /// 画面には件数しか出ず記録も残らないため、版をまたいで互換が崩れても（未知の
  /// キー・型違い・範囲外が増えても）気付けなかった。**キー名と理由だけ**を載せ、
  /// **値は載せない**（テンプレート履歴・フォント名などが入るため）。失敗ではなく
  /// 分布観測なので captureMessage（info）で、fingerprint は 1 本に集約する。
  void _reportImportSkips(SettingsImportResult result) {
    if (result.skipped.isEmpty) return;
    try {
      Sentry.captureMessage(
        'settings_backup: import skipped ${result.skipped.length} keys',
        level: SentryLevel.info,
        withScope: (scope) {
          scope.setTag('settings_backup.op', 'import_skip');
          // key -> 理由。値は含めない（result.skipped は key→理由 の対応）。
          scope.setContexts('settings_backup_skipped', {
            for (final entry in result.skipped.entries) entry.key: entry.value,
          });
          scope.fingerprint = ['settings_backup.op', 'import_skip'];
        },
      );
    } catch (_) {
      // Sentry 失敗で UI を止めない。
    }
  }

  String _importSummary(SettingsImportResult result) {
    if (result.applied.isEmpty && result.skipped.isEmpty) {
      return 'このファイルに取り込める設定はありませんでした';
    }
    final buffer = StringBuffer('${result.applied.length} 件の設定を読み込みました');
    if (result.skipped.isNotEmpty) {
      buffer.write('（${result.skipped.length} 件は取り込みませんでした）');
    }
    return buffer.toString();
  }

  /// 取り込んだ値を画面へ反映する (#857)。
  ///
  /// **[exportableSettings] と 1:1 で対応させること。**ここに足し忘れると、
  /// 値は書き込まれているのに次の起動まで画面へ出ない。
  void _refreshPreferenceProviders() {
    for (final provider in backedUpPreferenceProviders) {
      ref.invalidate(provider);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定のバックアップ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'この端末の設定をファイルに書き出し、別の端末で読み込めます。\n'
              'アカウントと認証情報は含まれません。読み込んだあとにログインし直してください。',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('設定を書き出す'),
            subtitle: const Text('YAML ファイルとして保存します'),
            enabled: !_busy,
            onTap: _export,
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('設定を読み込む'),
            subtitle: const Text('この端末の設定を上書きします'),
            enabled: !_busy,
            onTap: _import,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text(
              '次の設定は端末ごとに決めるものなので、書き出しに含まれません。\n'
              '・背景画像\n'
              '・絵文字などのパレットの高さ\n'
              '・ウィンドウ常駐、ログイン時に起動\n'
              '\n'
              'アカウントごとに決まる設定も含まれません（背景の濃さ、'
              'テーマ色、タブ構成、絵文字パレット、ピン留めハッシュタグなど）。',
            ),
          ),
        ],
      ),
    );
  }
}
