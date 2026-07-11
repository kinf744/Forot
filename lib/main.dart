import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/app_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/activation_screen.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: const StivarosApp(),
    ),
  );
}

class StivarosApp extends StatelessWidget {
  const StivarosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stivaros',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF6C63FF),
          secondary: const Color(0xFF00D9FF),
          surface: const Color(0xFF1E1E2C),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF121220),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}
