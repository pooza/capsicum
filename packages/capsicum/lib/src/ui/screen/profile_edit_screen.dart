import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/platform_providers.dart';
import '../../service/sentry_op_failure.dart';

class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  final _displayNameController = TextEditingController();
  final _bioController = TextEditingController();
  final List<_FieldEntry> _fields = [];
  XFile? _avatarFile;
  XFile? _bannerFile;
  bool _saving = false;
  int? _maxFields;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final account = ref.read(currentAccountProvider);
    if (account == null) return;

    try {
      final adapter = account.adapter;

      // Get max profile fields.
      if (adapter is ProfileEditSupport) {
        _maxFields = await (adapter as ProfileEditSupport)
            .getMaxProfileFields();
      }

      // For Mastodon, fetch source (plain-text bio/fields) via verifyCredentials.
      if (adapter is MastodonAdapter) {
        final credentials = await adapter.client.verifyCredentials();
        _displayNameController.text = credentials.displayName;
        final source = credentials.source;
        _bioController.text = (source?['note'] as String?) ?? '';
        final sourceFields = source?['fields'] as List<dynamic>? ?? [];
        for (final f in sourceFields) {
          final map = f as Map<String, dynamic>;
          _fields.add(
            _FieldEntry(
              name: TextEditingController(text: map['name'] as String? ?? ''),
              value: TextEditingController(text: map['value'] as String? ?? ''),
            ),
          );
        }
      } else {
        // Misskey: description is plain text.
        final user = account.user;
        _displayNameController.text = user.displayName ?? '';
        _bioController.text = user.description ?? '';
        for (final f in user.fields) {
          _fields.add(
            _FieldEntry(
              name: TextEditingController(text: f.name),
              value: TextEditingController(text: f.value),
            ),
          );
        }
      }

      if (mounted) setState(() => _loaded = true);
    } catch (e, st) {
      // verifyCredentials / max-fields 取得失敗。握り潰すと「読み込み失敗」しか
      // 残らず後追いできないため Sentry に流す（DioException の生 URL/認可は
      // reportOpFailure 内の scrub で落ちる）。
      reportOpFailure(
        tagKey: 'profile.op',
        operation: 'load',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('プロフィールの読み込みに失敗しました')));
      }
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    for (final f in _fields) {
      f.name.dispose();
      f.value.dispose();
    }
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final file = await ref.read(mediaPickerProvider).pickImage();
    if (file != null) setState(() => _avatarFile = file);
  }

  Future<void> _pickBanner() async {
    final file = await ref.read(mediaPickerProvider).pickImage();
    if (file != null) setState(() => _bannerFile = file);
  }

  void _addField() {
    setState(() {
      _fields.add(
        _FieldEntry(
          name: TextEditingController(),
          value: TextEditingController(),
        ),
      );
    });
  }

  void _removeField(int index) {
    final entry = _fields.removeAt(index);
    entry.name.dispose();
    entry.value.dispose();
    setState(() {});
  }

  Future<void> _save() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ProfileEditSupport) return;
    final account = ref.read(currentAccountProvider);

    // 補足情報は「項目名・値とも空」の行を送らない（未入力の UI 行）。さらに
    // Mastodon は「値はあるが項目名が空」の行を 422 で弾く
    // (EmptyProfileFieldNamesValidator)。公式 UI と同じ規律で、送信前に項目名の
    // 入力を促してブロックする（generic「保存に失敗」より分かりやすく、無効な
    // PATCH を投げない）。
    final fields = _fields
        .map(
          (f) =>
              UserField(name: f.name.text.trim(), value: f.value.text.trim()),
        )
        .where((f) => f.name.isNotEmpty || f.value.isNotEmpty)
        .toList();
    if (fields.any((f) => f.name.isEmpty && f.value.isNotEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('値のある補足情報には項目名が必要です。項目名を入力するか、値を空にしてください。'),
        ),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final updatedUser = await (adapter as ProfileEditSupport).updateProfile(
        displayName: _displayNameController.text,
        description: _bioController.text,
        avatarFilePath: _avatarFile?.path,
        bannerFilePath: _bannerFile?.path,
        fields: fields,
      );

      ref.read(accountManagerProvider.notifier).updateCurrentUser(updatedUser);

      if (mounted) context.pop(updatedUser);
    } catch (e, st) {
      // updateProfile (PATCH update_credentials / Misskey i/update) の失敗。
      // 「保存に失敗しました」だけだと 4.6 ステージング等での不安定を後追い
      // できないため Sentry に流す（status / path は scrub 済みで残る）。
      reportOpFailure(
        tagKey: 'profile.op',
        operation: 'save',
        error: e,
        stackTrace: st,
        account: account,
      );
      // バリデーション拒否（422/400）はどの検証で落ちたかを本文から特定する。
      // Mastodon の検証エラーは項目コード/説明で PII ではないが、念のため本文は
      // 切り詰める。フィールド数・名前/値の長さも添える（255 超や 4 超の切り分け）。
      if (e is DioException) {
        final status = e.response?.statusCode;
        if (status == 422 || status == 400) {
          final body = e.response?.data?.toString() ?? '';
          Sentry.captureMessage(
            'profile.save validation rejected ($status)',
            level: SentryLevel.warning,
            withScope: (scope) {
              scope.setTag('profile.validation', '$status');
              scope.setTag('host', account?.key.host ?? '-');
              scope.setContexts('profile_validation', {
                'body': body.length > 1000 ? body.substring(0, 1000) : body,
                'field_count': fields.length,
                'field_name_lengths': fields.map((f) => f.name.length).toList(),
                'field_value_lengths': fields
                    .map((f) => f.value.length)
                    .toList(),
              });
              scope.fingerprint = ['profile', 'validation', '$status'];
            },
          );
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存に失敗しました')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    final user = account?.user;

    return Scaffold(
      appBar: AppBar(
        title: const Text('プロフィール編集'),
        actions: [
          TextButton(
            onPressed: _saving || !_loaded ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBannerPicker(user),
                  const SizedBox(height: 16),
                  _buildAvatarPicker(user),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _displayNameController,
                    decoration: const InputDecoration(
                      labelText: '表示名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _bioController,
                    decoration: const InputDecoration(
                      labelText: '自己紹介',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    maxLines: 5,
                  ),
                  const SizedBox(height: 24),
                  _buildFieldsSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildBannerPicker(User? user) {
    final bannerWidget = _bannerFile != null
        ? Image.file(
            File(_bannerFile!.path),
            height: 150,
            width: double.infinity,
            fit: BoxFit.cover,
          )
        : (user?.bannerUrl != null
              ? Image.network(
                  user!.bannerUrl!,
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    height: 150,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: const Center(child: Icon(Icons.panorama, size: 48)),
                  ),
                )
              : Container(
                  height: 150,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Center(child: Icon(Icons.panorama, size: 48)),
                ));

    return GestureDetector(
      onTap: _pickBanner,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.center,
          children: [
            bannerWidget,
            Container(
              height: 150,
              color: Colors.black26,
              child: const Center(
                child: Icon(Icons.camera_alt, color: Colors.white, size: 32),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarPicker(User? user) {
    final avatarWidget = _avatarFile != null
        ? CircleAvatar(
            radius: 40,
            backgroundImage: FileImage(File(_avatarFile!.path)),
          )
        : CircleAvatar(
            radius: 40,
            backgroundImage: user?.avatarUrl != null
                ? NetworkImage(user!.avatarUrl!)
                : null,
            child: user?.avatarUrl == null
                ? const Icon(Icons.person, size: 40)
                : null,
          );

    return GestureDetector(
      onTap: _pickAvatar,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          avatarWidget,
          CircleAvatar(
            radius: 14,
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: Icon(
              Icons.camera_alt,
              size: 14,
              color: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldsSection() {
    final canAdd = _maxFields == null || _fields.length < _maxFields!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('補足情報', style: Theme.of(context).textTheme.titleMedium),
            if (canAdd)
              TextButton.icon(
                onPressed: _addField,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('追加'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _fields.length; i++) _buildFieldRow(i),
      ],
    );
  }

  Widget _buildFieldRow(int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: TextField(
              controller: _fields[index].name,
              decoration: const InputDecoration(
                labelText: '項目名',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextField(
              controller: _fields[index].value,
              decoration: const InputDecoration(
                labelText: '値',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          IconButton(
            onPressed: () => _removeField(index),
            icon: const Icon(Icons.remove_circle_outline),
            iconSize: 20,
          ),
        ],
      ),
    );
  }
}

class _FieldEntry {
  final TextEditingController name;
  final TextEditingController value;

  _FieldEntry({required this.name, required this.value});
}
