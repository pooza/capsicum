import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants.dart';
import '../../model/account_key.dart';
import '../../preset_servers.dart';
import '../../service/settings_backup.dart';
import '../../platform/platform_info.dart';
import '../../url_helper.dart';
import '../../util/exception_scrub.dart';
import '../util/settings_backup_file_type.dart';

class ServerSelectionScreen extends ConsumerStatefulWidget {
  const ServerSelectionScreen({super.key, this.initialHost});

  /// 接続先を埋めた状態で開く (#967)。未接続アカウントから「接続し直す」で
  /// 来たとき、ホスト名を打ち直させないため。
  final String? initialHost;

  @override
  ConsumerState<ServerSelectionScreen> createState() =>
      _ServerSelectionScreenState();
}

class _ServerSelectionScreenState extends ConsumerState<ServerSelectionScreen> {
  late final _hostController = TextEditingController(
    text: widget.initialHost ?? '',
  );
  bool _isProbing = false;
  String? _error;

  /// バックアップ取り込み中（二重起動を止める）。
  bool _importing = false;

  /// 取り込んだアカウントのホスト。⚠ **ログイン前はアカウント一覧の画面が無い**
  /// ので、ここに出さないと「読み込めたのか」がユーザーから見えない (#1001)。
  List<String> _importedHosts = const [];

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  /// バックアップを取り込む (#1001)。**ログイン前でも使える唯一の導線**。
  ///
  /// 取り込むのは設定とアカウント索引だけで、トークンは入っていない（#857）。
  /// したがってここで即ログイン状態にはならない。**ホスト名を埋めて、ログインへ
  /// 送るところまで**が役割で、ログインすると残りは「未接続」として一覧に並ぶ
  /// （#967）。
  Future<void> _importBackup() async {
    final file = await openFile(
      acceptedTypeGroups: [
        settingsBackupTypeGroup(needsUti: fileTypeFilterNeedsUti),
      ],
    );
    if (file == null || !mounted) return;

    setState(() {
      _importing = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final text = await File(file.path).readAsString();
      final prefs = await SharedPreferences.getInstance();
      final result = await applySettingsBackupYaml(prefs, text);
      if (!mounted) return;

      final hosts = <String>[];
      for (final raw in result.addedAccountKeys) {
        try {
          hosts.add(AccountKey.fromStorageKey(raw).host);
        } catch (_) {
          continue;
        }
      }
      setState(() {
        _importedHosts = hosts.toSet().toList();
        // 最初のホストを埋めておく。移行直後にホスト名を打ち直させない
        // （#967 の「接続し直す」導線と同じ考え方）。
        if (_hostController.text.isEmpty && hosts.isNotEmpty) {
          _hostController.text = hosts.first;
        }
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            hosts.isEmpty
                ? '設定を読み込みました'
                : '設定と ${result.addedAccountKeys.length} 件のアカウントを読み込みました。'
                      'ログインすると使えるようになります',
          ),
        ),
      );
    } on SettingsBackupFormatException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('読み込めませんでした: $e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _connectTo(String host) async {
    setState(() {
      _isProbing = true;
      _error = null;
    });

    try {
      // タイムアウトを明示する。#723 で probeInstance が NodeInfo → /api/meta →
      // /api/v1/instance を直列に試すようになったため、パケットを黙って捨てる
      // blackhole ホストでは無指定だと OS 既定 × 最大3回ぶんハングし得る。
      final dio = Dio(
        BaseOptions(
          connectTimeout: kNetworkConnectTimeout,
          receiveTimeout: kNetworkReceiveTimeout,
        ),
      );
      final probe = await probeInstance(dio, host);
      // async gap 後に widget が dispose されているケース (CAPSICUM-1D / #472)。
      // 以下の各 setState 前に必ず mounted ガード。
      if (!mounted) return;
      if (probe == null) {
        setState(() {
          _error = 'サポートされていないサーバーです';
          _isProbing = false;
        });
        return;
      }

      context.push(
        '/login',
        extra: {
          'host': host,
          'backendType': probe.type,
          'softwareVersion': probe.softwareVersion,
        },
      );
    } catch (e) {
      debugLogException('Server probe error', e);
      if (!mounted) return;
      setState(() {
        _error = '接続に失敗しました';
      });
    } finally {
      if (mounted) setState(() => _isProbing = false);
    }
  }

  void _onSubmit() {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    _connectTo(host);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: _isProbing
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SizedBox(height: 16),
                Center(
                  child: Image.asset('assets/images/logo.png', height: 96),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    'プリセットサーバーを選択',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('プリセットサーバーについて'),
                    onPressed: () => launchUrlSafely(
                      AppConstants.presetServersUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ...visiblePresetServers().map((server) {
                  return ListTile(
                    leading: const Icon(Icons.dns),
                    title: Text(server.displayName),
                    subtitle: Text(server.host),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    onTap: () => _connectTo(server.host),
                  );
                }),
                const Divider(height: 32),
                TextField(
                  controller: _hostController,
                  decoration: InputDecoration(
                    labelText: 'その他のサーバー',
                    hintText: 'example.com',
                    errorText: _error,
                    prefixIcon: const Icon(Icons.dns),
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _onSubmit(),
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _onSubmit, child: const Text('接続')),
                const Divider(height: 32),
                // ⚠ **ログイン前に置く**（Codex P1 / PR #1002）。設定画面は
                // セッションが無いと router が /server へ引き戻すので、新しい
                // 端末では到達できない。**移行はここから始まる**ので、バック
                // アップの取り込みだけはログイン前に要る (#1001)。
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('バックアップから設定とアカウントを読み込む'),
                    onPressed: _importing ? null : _importBackup,
                  ),
                ),
                if (_importedHosts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '読み込んだアカウント: ${_importedHosts.join(" / ")}\n'
                      '上のサーバーを選んでログインすると使えるようになります。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
    );
  }
}
