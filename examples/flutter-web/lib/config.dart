import 'dart:convert';

import 'package:http/http.dart' as http;

/// Runtime config loaded from /config.json. web/config.json holds the local
/// development values; on the server each environment mounts its own file.
class AppConfig {
  const AppConfig({required this.environment, required this.apiBaseUrl});

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
    environment: json['environment'] as String,
    apiBaseUrl: json['apiBaseUrl'] as String,
  );

  final String environment;
  final String apiBaseUrl;

  static Future<AppConfig> load({http.Client? client}) async {
    // The query parameter bypasses any cached copy, e.g. in a service worker.
    final uri = Uri.base
        .resolve('/config.json')
        .replace(
          queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch}'},
        );
    final response = await (client ?? http.Client()).get(uri);
    if (response.statusCode != 200) {
      throw StateError('Loading $uri failed: HTTP ${response.statusCode}');
    }
    return AppConfig.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }
}
