import 'package:flutter/material.dart';

import 'config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await AppConfig.load();
  runApp(SampleApp(config: config));
}

class SampleApp extends StatelessWidget {
  const SampleApp({super.key, required this.config});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Sample frontend (${config.environment})')),
      ),
    );
  }
}
