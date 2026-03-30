import 'package:flutter_test/flutter_test.dart';

import 'package:shelf_finder/main.dart';

void main() {
  testWidgets('Home screen shows search field', (WidgetTester tester) async {
    await tester.pumpWidget(const ShelfFinderApp());

    expect(find.text('Shelf Lookup'), findsOneWidget);
    expect(find.text('šećer'), findsOneWidget);
    expect(find.text('Scan Shelf'), findsOneWidget);
  });
}
