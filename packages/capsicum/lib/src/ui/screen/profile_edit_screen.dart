import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../provider/account_manager_provider.dart';

class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  final _displayNameController = TextEditingController();
  final _bioController = TextEditingController();
  final _imagePicker = ImagePicker();
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
    } catch (_) {
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
    final file = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (file != null) setState(() => _avatarFile = file);
  }

  Future<void> _pickBanner() async {
    final file = await _imagePicker.pickImage(source: ImageSource.gallery);
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

    setState(() => _saving = true);

    try {
      final updatedUser = await (adapter as ProfileEditSupport).updateProfile(
        displayName: _displayNameController.text,
        description: _bioController.text,
        avatarFilePath: _avatarFile?.path,
        bannerFilePath: _bannerFile?.path,
        fields: _fields
            .map((f) => UserField(name: f.name.text, value: f.value.text))
            .toList(),
      );

      ref.read(accountManagerProvider.notifier).updateCurrentUser(updatedUser);

      if (mounted) context.pop(updatedUser);
    } catch (e) {
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
