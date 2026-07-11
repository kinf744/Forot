import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import 'activation_screen.dart';
import 'settings_screen.dart';
import 'config_selection_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _trafficTimer;

  @override
  void dispose() {
    _trafficTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Stivaros'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {
                    HapticFeedback.heavyImpact();
                    if (provider.isConnected) {
                      provider.disconnect();
                    } else if (provider.connectionState != VpnState.connecting) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ConfigSelectionScreen()),
                      );
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: _getGradient(provider, theme),
                      boxShadow: [
                        BoxShadow(
                          color: _getShadowColor(provider, theme).withOpacity(0.4),
                          blurRadius: 40,
                          spreadRadius: 10,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          provider.isConnected ? Icons.vpn_lock : Icons.vpn_key_off,
                          size: 48,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _getStatusText(provider),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                Text(
                  _getStatusLabel(provider),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: _getStatusColor(provider),
                  ),
                ),
                if (provider.modeLabel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${provider.modeLabel} · ${provider.ispLabel.toUpperCase()} · ${provider.serverConfig?.sni ?? provider.serverConfig?.address ?? ""}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),

                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.arrow_downward, size: 16, color: Colors.greenAccent),
                      const SizedBox(width: 6),
                      Text(
                        '${provider.formatBytes(provider.rxSpeed, bits: true)} ${provider.formatBytes(provider.rxBytes)}',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
                      ),
                      const SizedBox(width: 16),
                      const Text('-', style: TextStyle(color: Colors.white54)),
                      const SizedBox(width: 16),
                      const Icon(Icons.arrow_upward, size: 16, color: Colors.orangeAccent),
                      const SizedBox(width: 6),
                      Text(
                        '${provider.formatBytes(provider.txSpeed, bits: true)} ${provider.formatBytes(provider.txBytes)}',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                if (provider.serverConfig != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.dns, size: 16, color: theme.colorScheme.secondary),
                        const SizedBox(width: 8),
                        Text(
                          '${provider.serverConfig!.address}:${provider.serverConfig!.port}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),

                const Spacer(),

                TextButton.icon(
                  onPressed: () => _showLogoutDialog(context, provider),
                  icon: const Icon(Icons.logout, color: Colors.redAccent),
                  label: const Text('Logout', style: TextStyle(color: Colors.redAccent)),
                ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }

  Gradient _getGradient(AppProvider provider, ThemeData theme) {
    switch (provider.connectionState) {
      case VpnState.connected:
        return LinearGradient(colors: [const Color(0xFF00E676), const Color(0xFF00BFA5)]);
      case VpnState.connecting:
        return LinearGradient(colors: [Colors.amber, Colors.orange]);
      case VpnState.error:
        return LinearGradient(colors: [Colors.red, Colors.deepOrange]);
      default:
        return LinearGradient(colors: [theme.colorScheme.primary, theme.colorScheme.secondary]);
    }
  }

  Color _getShadowColor(AppProvider provider, ThemeData theme) {
    switch (provider.connectionState) {
      case VpnState.connected:
        return const Color(0xFF00E676);
      case VpnState.connecting:
        return Colors.amber;
      case VpnState.error:
        return Colors.red;
      default:
        return theme.colorScheme.primary;
    }
  }

  String _getStatusText(AppProvider provider) {
    switch (provider.connectionState) {
      case VpnState.connected:
        return 'Connected';
      case VpnState.connecting:
        return 'Connecting...';
      case VpnState.error:
        return 'Error';
      default:
        return 'Tap to Connect';
    }
  }

  String _getStatusLabel(AppProvider provider) {
    switch (provider.connectionState) {
      case VpnState.connected:
        return 'CONNECTED';
      case VpnState.connecting:
        return 'CONNECTING';
      case VpnState.error:
        return 'ERROR';
      default:
        return 'DISCONNECTED';
    }
  }

  Color? _getStatusColor(AppProvider provider) {
    switch (provider.connectionState) {
      case VpnState.connected:
        return const Color(0xFF00E676);
      case VpnState.connecting:
        return Colors.amber;
      case VpnState.error:
        return Colors.red;
      default:
        return Colors.white38;
    }
  }

  void _showLogoutDialog(BuildContext context, AppProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2C),
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to logout?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              provider.logout();
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const ActivationScreen()),
              );
            },
            child: const Text('Logout', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
