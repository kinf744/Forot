import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import 'home_screen.dart';

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  String _statusMessage = '';

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _copyDeviceId(AppProvider provider) {
    Clipboard.setData(ClipboardData(text: provider.deviceId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device ID copied'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _activate() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _statusMessage = 'Activation en cours...';
    });

    final provider = context.read<AppProvider>();
    final success = await provider.activate(
      phoneNumber: _phoneController.text.trim(),
      activationCode: _codeController.text.trim(),
    );

    if (!mounted) return;

    if (success) {
      setState(() => _statusMessage = 'Téléchargement des configurations...');

      await provider.autoConfig();

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.errorMessage),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppProvider>();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.vpn_key, size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text('Activate App', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 8),
                Text(
                  'Send your Device ID to the admin to get an activation code',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white54),
                ),
                const SizedBox(height: 24),

                // Device ID card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.primary.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Text('Device ID', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      SelectableText(
                        provider.deviceId,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _copyDeviceId(provider),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy Device ID'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.primary,
                            side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                Divider(color: Colors.white12, height: 1),
                const SizedBox(height: 24),

                // Activation form
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone Number',
                          prefixIcon: Icon(Icons.phone),
                        ),
                        style: const TextStyle(color: Colors.white),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Enter phone number' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _codeController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: 'Activation Code (6 digits)',
                          prefixIcon: Icon(Icons.lock),
                          counterText: '',
                        ),
                        style: const TextStyle(color: Colors.white),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Enter activation code';
                          if (v.trim().length != 6) return 'Code must be 6 digits';
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _activate,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _loading
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                                    const SizedBox(width: 12),
                                    Text(_statusMessage, style: const TextStyle(fontSize: 14, color: Colors.white)),
                                  ],
                                )
                              : const Text('Activate App', style: TextStyle(fontSize: 16, color: Colors.white)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
