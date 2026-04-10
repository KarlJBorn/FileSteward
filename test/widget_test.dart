import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/app_version.dart';
import 'package:filesteward/main.dart';

void main() {
  testWidgets('shows the Consolidate source selection screen on launch', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FileStewardApp());
    await tester.pumpAndSettle();

    // App bar shows title and version.
    expect(find.text('FileSteward'), findsOneWidget);
    expect(find.text('v$kAppVersion'), findsOneWidget);

    // Step progress bar labels are visible.
    expect(find.text('Select'), findsOneWidget);
    expect(find.text('Filter'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Build'), findsOneWidget);

    // Source selection UI is showing.
    expect(find.text('Add Folder…'), findsOneWidget);

    // Scan button is disabled (no folders added yet).
    expect(find.text('Scan Folder Structure'), findsOneWidget);
  });
}
