import 'package:flutter_test/flutter_test.dart';
import 'package:sample_frontend/main.dart';

void main() {
  testWidgets('shows the title', (tester) async {
    await tester.pumpWidget(const SampleApp());
    expect(find.text('Sample frontend'), findsOneWidget);
  });
}
