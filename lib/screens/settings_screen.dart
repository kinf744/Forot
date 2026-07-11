import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';

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
