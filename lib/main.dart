import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.load();
  runApp(TriliumApp(state: state));
}

class TriliumApp extends StatelessWidget {
  const TriliumApp({super.key, required this.state});

  final AppState state;

  static const seed = Color(0xFF4A6FA5);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trilium',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) => state.isConfigured ? HomeScreen(state: state) : SetupScreen(state: state),
      ),
    );
  }
}
