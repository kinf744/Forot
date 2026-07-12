import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/file_logger.dart';
import 'activation_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _connectionStep = 0;
  String _stepMessage = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadConfigs();
    });
  }

  Future<void> _startConnection(AppProvider provider) async {
    HapticFeedback.heavyImpact();
    if (provider.isConnected || provider.connectionState == VpnState.connecting) {
      provider.disconnect();
      return;
    }
    if (provider.connectionState == VpnState.error) {
      provider.clearError();
    }

    FileLogger().i('HomeScreen', 'Starting connection...');

    // Step 1: Ensure config is selected
    setState(() {
      _connectionStep = 1;
      _stepMessage = 'Préparation…';
    });
    await provider.autoConfig();
    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;
    if (provider.serverConfig == null) {
      setState(() => _connectionStep = 0);
      FileLogger().e('HomeScreen', 'autoConfig returned null config');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.errorMessage.isNotEmpty ? provider.errorMessage : 'Aucune configuration disponible'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Step 2: VPN tunnel
    setState(() {
      _connectionStep = 2;
      _stepMessage = 'Connexion en cours…';
    });
    await Future.delayed(const Duration(milliseconds: 300));

    if (provider.serverConfig != null) {
      FileLogger().i('HomeScreen', 'Calling provider.connect()...');
      final connected = await provider.connect();
      if (!mounted) return;
      setState(() => _connectionStep = 0);
      if (connected) {
        FileLogger().i('HomeScreen', 'connect() returned true');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connecté'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      } else if (provider.connectionState == VpnState.connecting) {
        FileLogger().i('HomeScreen', 'permission dialog shown, waiting for VPN...');
      } else {
        final msg = provider.errorMessage.isNotEmpty ? provider.errorMessage : 'Échec de connexion';
        FileLogger().e('HomeScreen', 'connect() returned false: $msg');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    }
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
          return Stack(
            children: [
              Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () => _startConnection(provider),
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
                // Config selector
                if (provider.configs.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: provider.selectedConfigIndex,
                        dropdownColor: const Color(0xFF1E1E2C),
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        icon: const Icon(Icons.expand_more, color: Colors.white54),
                        isDense: true,
                        hint: const Text('Choisir une config', style: TextStyle(color: Colors.white54)),
                        items: List.generate(provider.configs.length, (i) {
                          final c = provider.configs[i];
                          return DropdownMenuItem(
                            value: i,
                            child: Text(c['label'] as String? ?? 'Config ${i + 1}'),
                          );
                        }),
                        onChanged: (index) {
                          if (index != null) provider.selectConfig(index);
                        },
                      ),
                    ),
                  ),

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

                const Spacer(),

                TextButton.icon(
                  onPressed: () => _showLogoutDialog(context, provider),
                  icon: const Icon(Icons.logout, color: Colors.redAccent),
                  label: const Text('Logout', style: TextStyle(color: Colors.redAccent)),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
          if (_connectionStep > 0)
            GestureDetector(
              onTap: () => provider.disconnect(),
              child: Container(
                color: Colors.black54,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E2C),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 16),
                        Text(_stepMessage, style: const TextStyle(color: Colors.white, fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
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
