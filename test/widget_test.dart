import 'package:flutter_test/flutter_test.dart';
import 'package:camfishing_float/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const VirtualFloatApp());
  });
}
