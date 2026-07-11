import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import 'activation_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
                // Connection status card
                GestureDetector(
                  onTap: () {
                    HapticFeedback.heavyImpact();
                    if (provider.isConnected) {
                      provider.disconnect();
                    } else if (provider.connectionState != ConnectionState.connecting) {
                      provider.connect();
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
                          color: _getShadowColor(provider, theme).withValues(alpha: 0.4),
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
                const SizedBox(height: 32),

                // Data usage (placeholder)
                if (provider.isConnected) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildStatCard('Download', '0 MB', Icons.arrow_downward, theme),
                      const SizedBox(width: 24),
                      _buildStatCard('Upload', '0 MB', Icons.arrow_upward, theme),
                    ],
                  ),
                ],

                const SizedBox(height: 32),

                // Server info
                if (provider.serverConfig != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.5),
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

                // Logout
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
      case ConnectionState.connected:
        return LinearGradient(colors: [const Color(0xFF00E676), const Color(0xFF00BFA5)]);
      case ConnectionState.connecting:
        return LinearGradient(colors: [Colors.amber, Colors.orange]);
      case ConnectionState.error:
        return LinearGradient(colors: [Colors.red, Colors.deepOrange]);
      default:
        return LinearGradient(colors: [theme.colorScheme.primary, theme.colorScheme.secondary]);
    }
  }

  Color _getShadowColor(AppProvider provider, ThemeData theme) {
    switch (provider.connectionState) {
      case ConnectionState.connected:
        return const Color(0xFF00E676);
      case ConnectionState.connecting:
        return Colors.amber;
      case ConnectionState.error:
        return Colors.red;
      default:
        return theme.colorScheme.primary;
    }
  }

  String _getStatusText(AppProvider provider) {
    switch (provider.connectionState) {
      case ConnectionState.connected:
        return 'Connected';
      case ConnectionState.connecting:
        return 'Connecting...';
      case ConnectionState.error:
        return 'Error';
      default:
        return 'Tap to Connect';
    }
  }

  Widget _buildStatCard(String label, String value, IconData icon, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: theme.colorScheme.secondary, size: 20),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
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
