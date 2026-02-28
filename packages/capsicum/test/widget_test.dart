import 'package:flutter_test/flutter_test.dart';

import 'package:capsicum/main.dart';

void main() {
  testWidgets('App displays capsicum title', (WidgetTester tester) async {
    await tester.pumpWidget(const CapsicumApp());
    expect(find.text('capsicum'), findsWidgets);
  });
}
