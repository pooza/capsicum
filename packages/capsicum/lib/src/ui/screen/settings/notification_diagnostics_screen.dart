import 'package:flutter/material.dart';

import '../../../service/notification_diagnostics_service.dart';

/// Displays iOS background-task diagnostics (#293).
///
/// Shows task fire counts and last success time so that users and developers
/// can verify whether the BGTaskScheduler is actually running.
class NotificationDiagnosticsScreen extends StatefulWidget {
  const NotificationDiagnosticsScreen({super.key});

  @override
  State<NotificationDiagnosticsScreen> createState() =>
      _NotificationDiagnosticsScreenState();
}

class _NotificationDiagnosticsScreenState
    extends State<NotificationDiagnosticsScreen> {
  DiagnosticsSnapshot? _snapshot;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snap = await NotificationDiagnosticsService.getSnapshot();
    if (mounted) {
      setState(() {
        _snapshot = snap;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('通知の診断'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: _buildContent(theme),
              ),
            ),
    );
  }

  List<Widget> _buildContent(ThemeData theme) {
    final snap = _snapshot!;
    final items = <Widget>[];

    items.add(_SectionHeader('タスク実行履歴'));
    items.add(_DiagnosticTile(label: '累計発火回数', value: '${snap.fireCount} 回'));
    items.add(
      _DiagnosticTile(
        label: '最後の発火',
        value: _formatDateTime(snap.lastFireTime),
      ),
    );
    items.add(
      _DiagnosticTile(
        label: '最後の成功',
        value: _formatDateTime(snap.lastSuccessTime),
      ),
    );

    if (snap.lastFailureReason != null) {
      items.add(
        _DiagnosticTile(
          label: '最後の失敗',
          value: snap.lastFailureReason!,
          icon: Icons.error_outline,
          iconColor: Colors.red,
        ),
      );
    }

    items.add(const SizedBox(height: 24));
    items.add(
      Text(
        'iOS のバックグラウンドタスクは OS が最適なタイミングで実行します。'
        '発火間隔は 15 分以上開くことがあります。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );

    return items;
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return 'まだありません';
    final local = dt.toLocal();
    return '${local.year}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _DiagnosticTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final Color? iconColor;

  const _DiagnosticTile({
    required this.label,
    required this.value,
    this.icon,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: icon != null ? Icon(icon, color: iconColor, size: 20) : null,
      title: Text(label),
      trailing: Text(value, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
