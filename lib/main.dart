import 'package:flutter/material.dart';

import 'app_version.dart';
import 'consolidate_screen.dart';

void main() {
  runApp(const FileStewardApp());
}

class FileStewardApp extends StatelessWidget {
  const FileStewardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FileSteward Consolidate',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0E70C0),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.merge, size: 72, color: Color(0xFF0E70C0)),
              const SizedBox(height: 16),
              const Text(
                'FileSteward',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'v$kAppVersion',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              const Text(
                'Consolidate your backup folders into one.',
                style: TextStyle(fontSize: 15, color: Colors.grey),
              ),
              const SizedBox(height: 32),
              Builder(
                builder: (ctx) => ElevatedButton.icon(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ConsolidateScreen(),
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0E70C0),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 16),
                  ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text(
                    'Start Consolidating',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
