import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/app_version.dart';
import 'package:filesteward/main.dart';

void main() {
  testWidgets('shows the FileSteward single-folder scan workflow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FileStewardApp());
    await tester.pumpAndSettle();

    // App bar shows title and version subtitle.
    expect(find.text('FileSteward'), findsOneWidget);
    expect(find.text('v$kAppVersion'), findsOneWidget);

    // Folder selection button visible before any folder is chosen.
    expect(find.text('Select Folder'), findsOneWidget);

    // Force-rescan toggle label.
    expect(find.text('Force rescan'), findsOneWidget);

    // Results section should not appear until a scan is complete.
    expect(find.text('Source Folders'), findsNothing);
  });
}
