import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/app_version.dart';
import 'package:filesteward/main.dart';

void main() {
  testWidgets('shows the FileSteward Consolidate landing page', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FileStewardApp());
    await tester.pumpAndSettle();

    // App title visible.
    expect(find.text('FileSteward'), findsOneWidget);

    // Version label visible.
    expect(find.text('v$kAppVersion'), findsOneWidget);

    // Launch button visible.
    expect(find.text('Start Consolidating'), findsOneWidget);
  });
}
