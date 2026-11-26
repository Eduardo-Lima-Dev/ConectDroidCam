import 'package:conectdroidcam/shared/widgets/pairing_countdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('conta o tempo do código e avisa quando expira', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PairingCountdown(
          expiredText: 'Expirou.',
          lifetime: Duration(seconds: 65),
        ),
      ),
    );
    expect(find.text('O código expira em 1:05.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    expect(find.text('O código expira em 0:59.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 60));
    expect(find.text('Expirou.'), findsOneWidget);
  });
}
