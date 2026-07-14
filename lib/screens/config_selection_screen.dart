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

  Future<void> _connect(String mode, String label) async {
    setState(() {
      _loading = true;
      _statusMessage = 'Analyse du réseau...';
    });

    final provider = context.read<AppProvider>();
    if (provider.user == null) return;

    _statusMessage = 'Détection de l\'opérateur...';
    setState(() {});
    await Future.delayed(const Duration(milliseconds: 500));

    _statusMessage = 'Génération de la configuration...';
    setState(() {});

    final result = await ApiService.getAutoConfig(
      uuid: provider.user!.uuid,
      activationCode: provider.user!.activationCode,
      mode: mode,
      tier: provider.currentTier,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final serverConfig = ServerConfig.fromJson(result);
      final isp = result['isp'] as String? ?? 'unknown';
      final tier = result['tier'] as String? ?? '150';
      provider.setAutoConfig(serverConfig, isp, label, tier: tier);

      _statusMessage = 'Opérateur détecté : ${isp.toUpperCase()}';
      setState(() {});
      await Future.delayed(const Duration(milliseconds: 800));

      _statusMessage = 'Connexion VPN...';
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
            content: Text(provider.errorMessage.isNotEmpty ? provider.errorMessage : 'Échec de connexion'),
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
          content: Text(result['message'] as String? ?? 'Configuration indisponible'),
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
        title: const Text('Connexion'),
      ),
      body: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_tethering, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Prêt à connecter',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Détection automatique du réseau et configuration optimale',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : () => _connect('normal', 'Connexion'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.greenAccent.withOpacity(0.15),
                        foregroundColor: Colors.greenAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.greenAccent.withOpacity(0.4)),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.power_settings_new, size: 28),
                          SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Connexion', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                                Text('Démarrer le VPN', style: TextStyle(fontSize: 12, color: Colors.white54)),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_ios, size: 16),
                        ],
                      ),
                    ),
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
}
