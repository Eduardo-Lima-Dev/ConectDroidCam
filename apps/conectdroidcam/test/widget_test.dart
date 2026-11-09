import 'package:conectdroidcam/app/app.dart';
import 'package:conectdroidcam/features/sender/application/sender_controller.dart';
import 'package:conectdroidcam/features/sender/domain/sender_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/sender/fake_sender_platform.dart';

final androidOnly = TargetPlatformVariant.only(TargetPlatform.android);

Future<FakeSenderPlatform> pumpApp(WidgetTester tester) async {
  // A tela cheia chama o sistema para esconder as barras; nos testes não há sistema.
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (_) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );

  final platform = FakeSenderPlatform()..permissionGranted = true;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [senderPlatformProvider.overrideWithValue(platform)],
      child: const ConectDroidCamApp(),
    ),
  );
  await tester.pumpAndSettle();
  return platform;
}

void main() {
  testWidgets('mostra as três principais, o seletor de outras e o FPS', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('HD (1280×720)'), findsOneWidget);
    expect(find.text('Full HD (1920×1080)'), findsOneWidget);
    // O 2K sempre aparece com a resolução, e o motivo quando indisponível.
    expect(find.text('2K (2560×1440)'), findsOneWidget);
    expect(
      find.text('sem codificador H.264 por hardware para 2560×1440'),
      findsOneWidget,
    );
    // O rótulo do DropdownMenu é desenhado duas vezes (campo e rótulo flutuante).
    expect(find.text('Outras resoluções'), findsWidgets);
    expect(find.text('Quadros por segundo'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('Iniciar transmissão'), findsOneWidget);
    expect(
      find.textContaining('use apenas em uma rede em que você confia'),
      findsOneWidget,
    );
  }, variant: androidOnly);

  testWidgets('sem resoluções extras, o seletor de outras não aparece', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    final platform = FakeSenderPlatform()..permissionGranted = true;
    platform.capabilities = const SenderCapabilities(
      fpsOptions: [30],
      modes: [
        ModeAvailability(mode: VideoMode.hd, available: true),
        ModeAvailability(mode: VideoMode.fullHd, available: true),
        ModeAvailability(mode: VideoMode.qhd, available: true),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [senderPlatformProvider.overrideWithValue(platform)],
        child: const ConectDroidCamApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Outras resoluções'), findsNothing);
    expect(find.text('HD (1280×720)'), findsOneWidget);
  }, variant: androidOnly);

  testWidgets('transmitindo, só a resolução escolhida fica visível', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Full HD (1920×1080)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Iniciar transmissão'));
    await tester.pumpAndSettle();

    expect(find.text('Parar transmissão'), findsOneWidget);
    expect(find.text('Full HD (1920×1080)'), findsOneWidget);
    expect(find.text('Em uso'), findsOneWidget);
    expect(find.text('HD (1280×720)'), findsNothing);
    expect(find.text('2K (2560×1440)'), findsNothing);
    expect(find.text('Outras resoluções'), findsNothing);
    // O FPS continua disponível para mudar com a transmissão ligada.
    expect(find.text('Quadros por segundo'), findsOneWidget);
  }, variant: androidOnly);

  testWidgets(
    'trocar o FPS com a transmissão ligada chega ao código nativo',
    (tester) async {
      final platform = await pumpApp(tester);
      await tester.tap(find.text('Iniciar transmissão'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();

      expect(platform.setFpsCalls, [20]);
    },
    variant: androidOnly,
  );

  group('tela cheia', () {
    testWidgets(
      'tocar na prévia abre a tela cheia, com o painel escondido',
      (tester) async {
        await pumpApp(tester);
        expect(find.text('ConectDroidCam'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.fullscreen));
        await tester.pumpAndSettle();

        // Só os dois botões discretos: o painel de informações some.
        expect(find.byTooltip('Sair da tela cheia'), findsOneWidget);
        expect(find.byTooltip('Abrir o menu'), findsOneWidget);
        expect(find.text('ConectDroidCam'), findsNothing);
        expect(find.text('Iniciar transmissão'), findsNothing);
      },
      variant: androidOnly,
    );

    testWidgets(
      'o menu mostra as informações por cima da imagem e fecha de novo',
      (tester) async {
        await pumpApp(tester);
        await tester.tap(find.byIcon(Icons.fullscreen));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Abrir o menu'));
        await tester.pumpAndSettle();
        expect(find.text('ConectDroidCam'), findsOneWidget);
        expect(find.text('Iniciar transmissão'), findsOneWidget);
        expect(find.text('Quadros por segundo'), findsOneWidget);

        await tester.tap(find.byTooltip('Fechar o menu'));
        await tester.pumpAndSettle();
        expect(find.text('ConectDroidCam'), findsNothing);
        expect(find.byTooltip('Abrir o menu'), findsOneWidget);
      },
      variant: androidOnly,
    );

    testWidgets('sair da tela cheia volta ao painel como estava', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(find.text('Full HD (1920×1080)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sair da tela cheia'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Sair da tela cheia'), findsNothing);
      expect(find.text('ConectDroidCam'), findsOneWidget);
      expect(find.text('HD (1280×720)'), findsOneWidget);
      // A escolha feita antes de entrar na tela cheia continua valendo.
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Full HD (1920×1080)'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.selected, isTrue);
    }, variant: androidOnly);

    testWidgets(
      'o botão voltar sai da tela cheia antes de sair do app',
      (tester) async {
        await pumpApp(tester);
        await tester.tap(find.byIcon(Icons.fullscreen));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Sair da tela cheia'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        expect(find.byTooltip('Sair da tela cheia'), findsNothing);
        expect(find.text('ConectDroidCam'), findsOneWidget);
      },
      variant: androidOnly,
    );

    testWidgets(
      'transmitindo, o menu da tela cheia traz o endereço e o botão de parar',
      (tester) async {
        await pumpApp(tester);
        await tester.tap(find.text('Iniciar transmissão'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.fullscreen));
        await tester.pumpAndSettle();
        expect(find.textContaining('192.168.0.7'), findsNothing);

        await tester.tap(find.byTooltip('Abrir o menu'));
        await tester.pumpAndSettle();

        expect(find.textContaining('192.168.0.7:47821'), findsOneWidget);
        expect(find.text('Parar transmissão'), findsOneWidget);
      },
      variant: androidOnly,
    );
  });

  testWidgets(
    'em retrato, a tela se reorganiza em coluna sem estourar',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);

      await pumpApp(tester);

      expect(find.text('Iniciar transmissão'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: androidOnly,
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
