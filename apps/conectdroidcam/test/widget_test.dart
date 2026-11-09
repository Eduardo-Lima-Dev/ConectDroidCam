import 'package:conectdroidcam/app/app.dart';
import 'package:conectdroidcam/features/sender/application/sender_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/sender/fake_sender_platform.dart';

void main() {
  testWidgets(
    'no Android, mostra os perfis e o aviso de segurança',
    (tester) async {
      final platform = FakeSenderPlatform()..permissionGranted = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [senderPlatformProvider.overrideWithValue(platform)],
          child: const ConectDroidCamApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('HD (1280×720)'), findsOneWidget);
      expect(find.text('Full HD (1920×1080)'), findsOneWidget);
      // O 2K sempre aparece com a resolução, e o motivo quando indisponível.
      expect(find.text('2K (2560×1440)'), findsOneWidget);
      expect(find.text('a câmera não oferece 2560×1440'), findsOneWidget);
      expect(find.text('Iniciar transmissão'), findsOneWidget);
      expect(
        find.textContaining('use apenas em uma rede em que você confia'),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'no computador, mostra a tela provisória do receptor',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ConectDroidCamApp()));
      await tester.pumpAndSettle();

      expect(find.text('Receptor em desenvolvimento'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
