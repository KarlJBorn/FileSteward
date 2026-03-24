import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/main.dart';

void main() {
  testWidgets('shows the FileSteward manifest workflow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FileStewardApp());

    expect(find.text('FileSteward'), findsOneWidget);
    expect(find.text('Selected folder'), findsOneWidget);
    expect(
      find.text('Choose a folder, then build a recursive manifest.'),
      findsOneWidget,
    );
    expect(find.text('Choose Folder'), findsOneWidget);
    expect(find.text('Build Manifest'), findsOneWidget);
    expect(find.text('Review manifest'), findsNothing);
  });
}
