import 'package:flutter/material.dart';
import 'scanner_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShelfFinderApp());
}

class ShelfFinderApp extends StatelessWidget {
  const ShelfFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpotText',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const ScannerScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
