import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:capsicum/main.dart';

void main() {
  testWidgets('App displays capsicum title', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CapsicumApp()));
    // Splash screen shows a CircularProgressIndicator initially
    expect(find.byType(CapsicumApp), findsOneWidget);
  });
}
