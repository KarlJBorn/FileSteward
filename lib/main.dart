import 'package:flutter/material.dart';

import 'consolidate_screen.dart';

void main() {
  runApp(const FileStewardApp());
}

class FileStewardApp extends StatelessWidget {
  const FileStewardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FileSteward',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0E70C0),
        useMaterial3: true,
      ),
      home: const ConsolidateScreen(),
    );
  }
}

