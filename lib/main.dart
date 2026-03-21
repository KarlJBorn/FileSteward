import 'package:flutter/material.dart';

void main() {
  runApp(const FileStewardApp());
}

class FileStewardApp extends StatelessWidget {
  const FileStewardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FileSteward',
      home: const FileStewardHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class FileStewardHomePage extends StatelessWidget {
  const FileStewardHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FileSteward'),
      ),
      body: const Center(
        child: Text(
          'Hello from FileSteward',
          style: TextStyle(fontSize: 24),
        ),
      ),
      floatingActionButton: ElevatedButton(
        onPressed: null,
        child: const Text('Next step coming soon'),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}
