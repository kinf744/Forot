import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../models/server_config.dart';
import 'home_screen.dart';

class ConfigSelectionScreen extends StatefulWidget {
  const ConfigSelectionScreen({super.key});

  @override
  State<ConfigSelectionScreen> createState() => _ConfigSelectionScreenState();
}

class _ConfigSelectionScreenState extends State<ConfigSelectionScreen> {
  bool _loading = false;
  String _statusMessage = '';

  Future<void> _selectMode(String mode, String label) async {
    setState(() {
      _loading = true;
      _statusMessage = 'Detecting network...';
    });

    final provider = context.read<AppProvider>();
    if (provider.user == null) return;

    _statusMessage = 'Analyzing ISP...';
    setState(() {});

    final result = await ApiService.getAutoConfig(
      uuid: provider.user!.uuid,
      activationCode: provider.user!.activationCode,
      mode: mode,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final serverConfig = ServerConfig.fromJson(result);
      provider.setAutoConfig(serverConfig, result['isp'] as String? ?? 'unknown', label);

      _statusMessage = 'Connecting VPN...';
      setState(() {});

      final connected = await provider.connect();

      if (!mounted) return;

      if (connected) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      } else {
        setState(() {
          _loading = false;
          _statusMessage = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(provider.errorMessage.isNotEmpty ? provider.errorMessage : 'Connection failed'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else {
      setState(() {
        _loading = false;
        _statusMessage = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message'] as String? ?? 'Failed to get config'),
          backgroundColor: Colors.red,
        ),
      );
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
        title: const Text('Select Mode'),
      ),
      body: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speed, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Choose connection mode',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The app will detect your network and load the best config',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                  const SizedBox(height: 32),

                  _buildModeButton(
                    icon: Icons.wifi,
                    title: 'Normal',
                    subtitle: 'Balanced performance',
                    color: theme.colorScheme.primary,
                    onTap: () => _selectMode('normal', 'Normal'),
                  ),
                  const SizedBox(height: 16),
                  _buildModeButton(
                    icon: Icons.signal_wifi_off,
                    title: 'Mauvaise réseau',
                    subtitle: 'Optimized for weak signals',
                    color: Colors.orange,
                    onTap: () => _selectMode('bad', 'Mauvaise réseau'),
                  ),
                  const SizedBox(height: 16),
                  _buildModeButton(
                    icon: Icons.flash_on,
                    title: 'Vitesse max',
                    subtitle: 'Maximum speed for stable networks',
                    color: Colors.greenAccent,
                    onTap: () => _selectMode('speed', 'Vitesse max'),
                  ),
                ],
              ),
            ),
          ),

          if (_loading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E2C),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(_statusMessage, style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildModeButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withOpacity(0.15),
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: color.withOpacity(0.4)),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 16),
          ],
        ),
      ),
    );
  }
}
