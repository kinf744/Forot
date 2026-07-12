import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/app_provider.dart';
import '../services/file_logger.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppProvider>();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSection('Connection', [
            SwitchListTile(
              title: const Text('Auto-connect on boot'),
              subtitle: const Text('Connect VPN when device starts'),
              value: false,
              onChanged: (_) {},
              activeColor: theme.colorScheme.primary,
            ),
            SwitchListTile(
              title: const Text('Kill switch'),
              subtitle: const Text('Block traffic if VPN disconnects'),
              value: false,
              onChanged: (_) {},
              activeColor: theme.colorScheme.primary,
            ),
          ], theme),

          const SizedBox(height: 16),
          _buildSection('Protocol', [
            ListTile(
              title: const Text('Tunnel Protocol'),
              subtitle: Text(provider.serverConfig?.protocol.toUpperCase() ?? 'VLESS'),
            ),
            ListTile(
              title: const Text('Transport'),
              subtitle: Text(provider.serverConfig?.transport.toUpperCase() ?? 'TCP'),
            ),
          ], theme),

          const SizedBox(height: 16),
          _buildSection('Device Info', [
            if (provider.user != null) ...[
              ListTile(
                title: const Text('Device ID / UUID'),
                subtitle: Text(
                  provider.deviceId,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: provider.deviceId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('UUID copié'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
                dense: true,
              ),
              ListTile(
                title: const Text('Phone'),
                subtitle: Text(provider.user!.phoneNumber),
                dense: true,
              ),
            ],
          ], theme),

          const SizedBox(height: 16),
          _buildSection('Debug', [
            ListTile(
              leading: const Icon(Icons.bug_report, size: 20),
              title: const Text('View Logs'),
              subtitle: const Text('Check connection logs'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const LogsScreen(),
              )),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt, size: 20),
              title: const Text('Export Logs'),
              subtitle: const Text('Save logs.txt to Downloads'),
              onTap: () async {
                try {
                  await FileLogger().copyToDownloads();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Logs saved to Downloads/mtn.txt')),
                    );
                  }
                } catch (_) {}
              },
            ),
          ], theme),

          const SizedBox(height: 16),
          Center(
            child: Text(
              'Stivaros v1.0.0',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> tiles, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withOpacity(0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(children: tiles),
        ),
      ],
    );
  }
}

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String _logs = 'Loading...';
  ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/mtn.txt');
      if (await file.exists()) {
        final content = await file.readAsString();
        final lines = content.split('\n');
        // Show last 500 lines
        final trimmed = lines.length > 500 ? lines.sublist(lines.length - 500) : lines;
        if (mounted) {
          setState(() => _logs = trimmed.join('\n'));
        }
      } else {
        if (mounted) setState(() => _logs = 'No logs yet');
      }
    } catch (e) {
      if (mounted) setState(() => _logs = 'Error: $e');
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Connection Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLogs,
          ),
          IconButton(
            icon: const Icon(Icons.content_copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _logs));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied')),
              );
            },
          ),
        ],
      ),
      body: GestureDetector(
        onLongPress: _loadLogs,
        child: SelectableText(
          _logs,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 10,
            color: Color(0xFFE0E0E0),
            height: 1.3,
          ),
        ),
      ),
    );
  }
}
