import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sample_frontend/config.dart';
import 'package:sample_frontend/main.dart';

void main() {
  test('loads config.json', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/config.json');
      return http.Response(
        '{"environment":"staging","apiBaseUrl":"https://api.staging.example.com"}',
        200,
      );
    });
    final config = await AppConfig.load(client: client);
    expect(config.environment, 'staging');
    expect(config.apiBaseUrl, 'https://api.staging.example.com');
  });

  test('fails loudly when config.json is missing', () async {
    final client = MockClient((_) async => http.Response('not found', 404));
    expect(AppConfig.load(client: client), throwsStateError);
  });

  testWidgets('shows the environment', (tester) async {
    const config = AppConfig(
      environment: 'staging',
      apiBaseUrl: 'https://api.staging.example.com',
    );
    await tester.pumpWidget(const SampleApp(config: config));
    expect(find.text('Sample frontend (staging)'), findsOneWidget);
  });
}
