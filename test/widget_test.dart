import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/main.dart';

void main() {
  testWidgets('shows the FileSteward multi-source scan workflow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FileStewardApp());

    // App bar title.
    expect(find.text('FileSteward'), findsOneWidget);

    // Section heading visible before any folder is added.
    expect(find.text('Source Folders'), findsOneWidget);

    // Empty-state hint message.
    expect(
      find.text(
        'No folders added yet. Add one or more source folders to scan.',
      ),
      findsOneWidget,
    );

    // Bottom bar action buttons.
    expect(find.text('Add Folder'), findsOneWidget);
    expect(find.text('Scan All'), findsOneWidget);

    // Force-rescan toggle label.
    expect(find.text('Force rescan'), findsOneWidget);

    // Results section should not appear until a scan is complete.
    expect(find.text('Review manifest'), findsNothing);
  });
}
