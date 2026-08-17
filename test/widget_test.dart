// اختبار دخاني: التطبيق يركب بلا انهيار — الغلاف WebView لا منطق فيه يُختبر
import 'package:flutter_test/flutter_test.dart';
import 'package:shater_app/main.dart';

void main() {
  testWidgets('app builds', (tester) async {
    await tester.pumpWidget(const ShaterApp());
    expect(find.byType(ShaterApp), findsOneWidget);
  });
}
