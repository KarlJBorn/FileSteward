import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/main.dart';

void main() {
  testWidgets('shows the FileSteward single-folder scan workflow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FileStewardApp());

    // Splash screen should be visible first.
    expect(find.text('FileSteward'), findsOneWidget);
    expect(find.text('v0.3.2'), findsOneWidget);

    // Advance past the splash timer and settle the navigation animation.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    // App bar title still present on home page.
    expect(find.text('FileSteward'), findsOneWidget);

    // Folder selection button visible before any folder is chosen.
    expect(find.text('Select Folder'), findsOneWidget);

    // Force-rescan toggle label.
    expect(find.text('Force rescan'), findsOneWidget);

    // Results section should not appear until a scan is complete.
    expect(find.text('Source Folders'), findsNothing);
  });
}
