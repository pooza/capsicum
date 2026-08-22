import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../platform/platform_info.dart';
import '../../../service/sentry_op_failure.dart';
import '../../../service/settings_backup.dart';
import '../../util/settings_backup_apply.dart';
import '../../util/settings_backup_file_type.dart';

/// 設定のバックアップ (#857)。
///
/// アカウント・認証情報は含まない（理由は [settings_backup.dart] の doc）。
///
/// 書き出し先の取り方だけプラットフォームで分かれる (#972)。デスクトップは
/// `file_selector` の保存ダイアログ、モバイルは OS の共有シート
/// （`file_selector` の `getSaveLocation` がモバイルでは未実装のため）。
/// 読み込み側の `openFile` は 5 OS すべてで実装されているので分岐は無い。
class SettingsBackupScreen extends ConsumerStatefulWidget {
  const SettingsBackupScreen({super.key});

  @override
  ConsumerState<SettingsBackupScreen> createState() =>
      _SettingsBackupScreenState();
}

class _SettingsBackupScreenState extends ConsumerState<SettingsBackupScreen> {
  bool _busy = false;

  /// 型グループの中身とプラットフォーム差は [settingsBackupTypeGroup] の doc。
  static XTypeGroup get _typeGroup =>
      settingsBackupTypeGroup(needsUti: fileTypeFilterNeedsUti);

  static const _fileName = 'capsicum-settings.yaml';

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 保存ダイアログのあるデスクトップは、先に保存先を聞いてから中身を作る
      // （キャンセルなら prefs も読まない）。モバイルは保存ダイアログが無いので
      // location は null のままで、下で共有シートへ渡す (#972)。
      FileSaveLocation? location;
      if (supportsFileSaveDialog) {
        location = await getSaveLocation(
          suggestedName: _fileName,
          acceptedTypeGroups: [_typeGroup],
        );
        if (location == null) return; // キャンセル
      }

      final prefs = await SharedPreferences.getInstance();
      final info = await PackageInfo.fromPlatform();
      final yaml = buildSettingsBackupYaml(
        prefs,
        appVersion: '${info.version}+${info.buildNumber}',
        exportedAt: DateTime.now().toUtc().toIso8601String(),
      );
      if (location != null) {
        await File(location.path).writeAsString(yaml);
        messenger.showSnackBar(const SnackBar(content: Text('設定を書き出しました')));
      } else {
        await _shareExport(yaml);
      }
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

  /// 保存ダイアログを持たないプラットフォーム向けの書き出し (#972)。
  ///
  /// 一時ファイルへ書いてから OS の共有シートに渡し、保存先の選択はユーザーへ
  /// 委ねる。iOS は「ファイルに保存」、Android は Drive / Files などが並ぶので、
  /// iCloud Drive / Google Drive を挟めば PC 側と往復できる（この Issue の動機）。
  ///
  /// ⚠ **一時ファイルは消さない。** 共有シートは受け取り側アプリが実ファイルを
  /// 非同期に読むため、`share` の完了を待って削除すると読み取り前に消えうる。
  /// 置き場が一時ディレクトリなので OS がいずれ回収する。
  Future<void> _shareExport(String yaml) async {
    final messenger = ScaffoldMessenger.of(context);
    // iPad の共有シートは popover なのでアンカーが要る（無いと iOS 側が例外を
    // 投げる）。await をまたぐ前に取る。
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$_fileName');
    await file.writeAsString(yaml);

    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/x-yaml')],
        fileNameOverrides: [_fileName],
        subject: '設定のバックアップ',
        sharePositionOrigin: origin,
      ),
    );
    // dismissed はユーザーが閉じただけなので黙って戻る。unavailable は「共有は
    // したが結果を追えない」なので成功側に寄せる（Android はこれになりうる）。
    if (result.status == ShareResultStatus.dismissed) return;
    messenger.showSnackBar(const SnackBar(content: Text('設定を書き出しました')));
  }

  Future<void> _import() async {
    if (_busy) return;
    final file = await openFile(acceptedTypeGroups: [_typeGroup]);
    if (file == null || !mounted) return; // キャンセル

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('設定を読み込む'),
        content: const Text(
          'この端末の設定が、ファイルの内容で上書きされます。\n'
          'ファイルに入っているアカウントは一覧へ追加されます'
          '（この端末の既存のアカウントは消えません）。よろしいですか？',
        ),
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
      // 設定とアカウントの反映は共通ヘルパーへ寄せてある（ログイン前の経路と
      // 割れないようにするため・Codex P2 / PR #1002）。
      applyImportedSettingsBackup(ref, result);
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
    if (result.applied.isEmpty &&
        result.skipped.isEmpty &&
        result.addedAccountKeys.isEmpty) {
      return 'このファイルに取り込める設定はありませんでした';
    }
    final buffer = StringBuffer('${result.applied.length} 件の設定を読み込みました');
    // ⚠ **アカウントは「追加した」で止め、使えるとは言わない** (#1001)。
    // トークンは移らないので、ログインし直すまで未接続のまま並ぶ (#967)。
    if (result.addedAccountKeys.isNotEmpty) {
      buffer.write(
        '。${result.addedAccountKeys.length} 件のアカウントを追加しました'
        '（未接続。ログインし直すと使えます）',
      );
    }
    if (result.skipped.isNotEmpty) {
      buffer.write('（${result.skipped.length} 件は取り込みませんでした）');
    }
    return buffer.toString();
  }

  /// 取り込んだ値を画面へ反映する (#857)。
  ///
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
              'アカウントの一覧（サーバーとユーザー名）も含まれますが、'
              'パスワードとアクセストークンは含まれません。\n'
              '読み込んだアカウントは「未接続」として並ぶので、ログインし直すと使えるようになります。',
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
