import 'package:conectdroidcam/app/app.dart';
import 'package:conectdroidcam/features/receiver/application/receiver_controller.dart';
import 'package:conectdroidcam/features/setup/data/system_probe.dart';
import 'package:conectdroidcam/features/setup/presentation/setup_wizard_page.dart';
import 'package:conectdroidcam/features/receiver/domain/receiver_models.dart';
import 'package:conectdroidcam/features/receiver/presentation/receiver_page.dart';
import 'package:conectdroidcam/features/sender/application/sender_controller.dart';
import 'package:conectdroidcam/features/sender/domain/sender_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/receiver/fake_receiver_platform.dart';
import 'features/sender/fake_sender_platform.dart';

final androidOnly = TargetPlatformVariant.only(TargetPlatform.android);

Future<FakeSenderPlatform> pumpApp(
  WidgetTester tester, {
  Size size = const Size(1200, 3000),
  double pixelRatio = 2,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
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
    expect(find.text('2K (2560×1440)'), findsOneWidget);
    expect(
      find.text('sem codificador H.264 por hardware para 2560×1440'),
      findsOneWidget,
    );
    expect(find.text('Outras resoluções'), findsWidgets);
    expect(find.text('Quadros por segundo'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('Iniciar transmissão'), findsOneWidget);
    expect(find.textContaining('A conexão é criptografada'), findsOneWidget);
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
      await pumpApp(tester, size: const Size(1080, 2400), pixelRatio: 2.75);

      expect(find.text('Iniciar transmissão'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: androidOnly,
  );

  group('computador (Linux)', () {
    final linux = TargetPlatformVariant.only(TargetPlatform.linux);

    Future<FakeReceiverPlatform> pumpReceiver(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final platform = FakeReceiverPlatform();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            receiverPlatformProvider.overrideWithValue(platform),
            receiverSettingsStoreProvider.overrideWithValue(
              FakeSettingsStore(),
            ),
          ],
          child: const ConectDroidCamApp(),
        ),
      );
      await tester.pumpAndSettle();
      return platform;
    }

    testWidgets('na primeira vez, abre o assistente e lembra ao concluir', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = FakeSettingsStore(const ReceiverSettings(setupDone: false));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            receiverPlatformProvider.overrideWithValue(FakeReceiverPlatform()),
            receiverSettingsStoreProvider.overrideWithValue(store),
            systemProbeProvider.overrideWithValue(
              const SystemProbe(root: '/caminho-que-nao-existe'),
            ),
          ],
          child: const ConectDroidCamApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Preparar este computador'), findsOneWidget);
      expect(find.text('Webcams do ConectDroidCam'), findsOneWidget);

      await tester.tap(find.text('Concluir'));
      await tester.pumpAndSettle();

      expect(find.text('Preparar este computador'), findsNothing);
      expect(store.settings.setupDone, isTrue);

      await tester.tap(find.byTooltip('Verificar o sistema'));
      await tester.pumpAndSettle();
      expect(find.text('Preparar este computador'), findsOneWidget);
    }, variant: linux);

    testWidgets('mostra os blocos do celular e da webcam virtual', (
      tester,
    ) async {
      await pumpReceiver(tester);

      expect(find.text('Celular'), findsOneWidget);
      expect(find.text('Webcam virtual'), findsOneWidget);
      expect(find.textContaining('Nenhum celular encontrado'), findsOneWidget);
      expect(find.text('Horizontal'), findsOneWidget);
      expect(find.text('Vertical'), findsOneWidget);
      expect(find.textContaining('A conexão é criptografada'), findsOneWidget);
    }, variant: linux);

    testWidgets('o celular achado na rede aparece e conecta com um toque', (
      tester,
    ) async {
      final platform = await pumpReceiver(tester);

      platform.phoneFound(
        const Phone(
          id: 'x',
          name: 'ConectDroidCam Pixel',
          address: '192.168.0.7:47821',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('ConectDroidCam Pixel'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('192.168.0.7:47821'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Conectar'));
      await tester.pumpAndSettle();

      expect(platform.lastAddress, '192.168.0.7:47821');
      expect(platform.lastDevice, isNull);
      expect(platform.lastShapeDevices, hasLength(6));
      expect(find.text('Desconectar'), findsOneWidget);
    }, variant: linux);

    testWidgets('conecta pelo endereço digitado', (tester) async {
      final platform = await pumpReceiver(tester);

      await tester.enterText(
        find.byKey(const Key('endereco')),
        '192.168.0.9:47821',
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Conectar'));
      await tester.pumpAndSettle();

      expect(platform.lastAddress, '192.168.0.9:47821');
    }, variant: linux);

    testWidgets('mostra a resolução real, a rotação e as estatísticas', (
      tester,
    ) async {
      final platform = await pumpReceiver(tester);
      await tester.enterText(
        find.byKey(const Key('endereco')),
        '192.168.0.9:47821',
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Conectar'));
      await tester.pumpAndSettle();

      platform.send(
        const HelloUpdate(deviceName: '2201117SL', platform: 'android'),
      );
      platform.send(
        const ProfileUpdate(
          IncomingVideo(
            width: 1920,
            height: 1080,
            fps: 30,
            bitrateKbps: 6000,
            rotation: 90,
          ),
        ),
      );
      platform.send(
        const OutputUpdate(
          OutgoingVideo(
            width: 1080,
            height: 1920,
            rotation: 90,
            device: '/dev/video11',
          ),
        ),
      );
      platform.send(
        const StatsUpdate(
          LiveStats(fps: 29.8, kbps: 6800, delayMs: 12, frames: 300),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Conectado a 2201117SL'), findsOneWidget);
      expect(find.text('Celular conectado'), findsOneWidget);
      expect(find.text('Endereço: 192.168.0.9:47821'), findsOneWidget);
      expect(find.text('Sistema: Android'), findsOneWidget);
      expect(find.text('Recebendo 1920×1080 a 30 FPS'), findsOneWidget);
      expect(find.text('Imagem girada 90° para ficar em pé'), findsOneWidget);
      expect(
        find.text(
          'Saída: 1080×1920 em ConectDroidCam FHD Vertical (/dev/video11)',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('atraso da rede 12 ms'), findsOneWidget);
    }, variant: linux);

    testWidgets('o cabeçalho diz o que está acontecendo, em cada etapa', (
      tester,
    ) async {
      final platform = await pumpReceiver(tester);
      expect(find.text('Procurando celulares na rede…'), findsOneWidget);

      platform.phoneFound(
        const Phone(id: 'x', name: 'Pixel', address: '192.168.0.7:47821'),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 celular encontrado na rede'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Conectar'));
      await tester.pump();
      expect(find.text('Conectando a Pixel…'), findsOneWidget);
    }, variant: linux);

    testWidgets(
      'a prévia vertical cabe em metade da janela, sem empurrar os controles',
      (tester) async {
        final platform = await pumpReceiver(tester);
        tester.view.physicalSize = const Size(900, 1000);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('endereco')),
          '192.168.0.9:47821',
        );
        await tester.tap(find.widgetWithText(OutlinedButton, 'Conectar'));
        await tester.pumpAndSettle();
        platform.send(
          const OutputUpdate(
            OutgoingVideo(width: 1080, height: 1920, rotation: 90),
          ),
        );
        await tester.pumpAndSettle();

        final box = tester.getSize(
          find.ancestor(
            of: find.text('Aguardando a imagem do celular…'),
            matching: find.byType(AspectRatio),
          ),
        );
        expect(box.height, lessThanOrEqualTo(500));
        expect(box.width / box.height, closeTo(1080 / 1920, 0.01));
      },
      variant: linux,
    );

    test('o limite da prévia é metade da janela, com um mínimo legível', () {
      expect(previewMaxHeight(1000), 500);
      expect(previewMaxHeight(200), 180);
    });

    testWidgets('mostra a prévia quando o celular manda quadros', (
      tester,
    ) async {
      final platform = await pumpReceiver(tester);
      await tester.enterText(
        find.byKey(const Key('endereco')),
        '192.168.0.9:47821',
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Conectar'));
      await tester.pumpAndSettle();
      expect(find.text('Aguardando a imagem do celular…'), findsOneWidget);

      platform.send(
        PreviewUpdate(
          Uint8List.fromList(const [
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
            0,
            0,
            0,
            0x0D,
            0x49,
            0x48,
            0x44,
            0x52,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            1,
            8,
            6,
            0,
            0,
            0,
            0x1F,
            0x15,
            0xC4,
            0x89,
            0,
            0,
            0,
            0x0D,
            0x49,
            0x44,
            0x41,
            0x54,
            0x78,
            0x9C,
            0x63,
            0xF8,
            0xFF,
            0xFF,
            0x3F,
            0,
            0x05,
            0xFE,
            0x02,
            0xFE,
            0xA7,
            0x35,
            0x81,
            0x84,
            0,
            0,
            0,
            0,
            0x49,
            0x45,
            0x4E,
            0x44,
            0xAE,
            0x42,
            0x60,
            0x82,
          ]),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Aguardando a imagem do celular…'), findsNothing);
      expect(find.byType(Image), findsWidgets);
    }, variant: linux);

    testWidgets(
      'mostra o selo de celular pareado e a opção de conexão automática',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final platform = FakeReceiverPlatform();
        final store = FakeSettingsStore(
          const ReceiverSettings(autoConnect: false, trustedPhones: {'x'}),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              receiverPlatformProvider.overrideWithValue(platform),
              receiverSettingsStoreProvider.overrideWithValue(store),
            ],
            child: const ConectDroidCamApp(),
          ),
        );
        await tester.pumpAndSettle();
        platform.phoneFound(
          const Phone(id: 'x', name: 'Pixel', address: '192.168.0.7:47821'),
        );
        await tester.pumpAndSettle();

        expect(find.text('192.168.0.7:47821 · pareado'), findsOneWidget);
        expect(
          find.text('Conectar sozinho aos celulares pareados'),
          findsOneWidget,
        );
        expect(find.text('Procurar de novo'), findsOneWidget);
        expect(find.text('Celulares pareados'), findsOneWidget);
        expect(find.byTooltip('Remover pareamento'), findsOneWidget);
        expect(find.textContaining('Esquecer todos'), findsNothing);
        final chave = tester.widget<SwitchListTile>(
          find.byType(SwitchListTile),
        );
        expect(chave.value, isFalse);

        await tester.tap(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
        expect(store.settings.autoConnect, isTrue);
      },
      variant: linux,
    );

    testWidgets(
      'esquecer os celulares lembrados limpa a lista e o botão some',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final platform = FakeReceiverPlatform();
        final store = FakeSettingsStore(
          const ReceiverSettings(autoConnect: false, trustedPhones: {'x'}),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              receiverPlatformProvider.overrideWithValue(platform),
              receiverSettingsStoreProvider.overrideWithValue(store),
            ],
            child: const ConectDroidCamApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Remover pareamento'));
        await tester.pumpAndSettle();
        expect(find.text('Remover o pareamento com x?'), findsOneWidget);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(store.settings.trustedPhones, {'x'});

        await tester.tap(find.byTooltip('Remover pareamento'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Remover'));
        await tester.pumpAndSettle();

        expect(store.settings.trustedPhones, isEmpty);
        expect(find.text('Celulares pareados'), findsNothing);
      },
      variant: linux,
    );

    testWidgets('o formato tem três opções e trocá-lo é lembrado', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final platform = FakeReceiverPlatform();
      final store = FakeSettingsStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            receiverPlatformProvider.overrideWithValue(platform),
            receiverSettingsStoreProvider.overrideWithValue(store),
          ],
          child: const ConectDroidCamApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Full HD (1920×1080)'), findsOneWidget);
      expect(find.text('HD (1280×720)'), findsOneWidget);
      expect(find.text('2K (2560×1440)'), findsOneWidget);
      expect(find.text('Automático'), findsOneWidget);
      expect(find.text('Horizontal'), findsOneWidget);
      expect(find.text('Vertical'), findsOneWidget);
      expect(find.textContaining('ConectDroidCam FHD Vertical'), findsWidgets);

      await tester.tap(find.text('Vertical'));
      await tester.pumpAndSettle();

      expect(store.settings.format, ImageFormat.vertical);
    }, variant: linux);

    testWidgets('sem a webcam do ConectDroidCam, ensina a criá-la', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final platform = FakeReceiverPlatform()..devices = const [];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            receiverPlatformProvider.overrideWithValue(platform),
            receiverSettingsStoreProvider.overrideWithValue(
              FakeSettingsStore(),
            ),
          ],
          child: const ConectDroidCamApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Nenhuma webcam virtual encontrada'),
        findsOneWidget,
      );
      expect(find.textContaining('linux-webcam-virtual.sh'), findsWidgets);
    }, variant: linux);

    test('comando de setup da webcam virtual muda dentro do Flatpak', () {
      expect(
        virtualWebcamSetupCommand(environment: const {}, exists: (_) => false),
        'sudo scripts/setup/linux-webcam-virtual.sh',
      );
      expect(
        virtualWebcamSetupCommand(
          environment: const {},
          executable: '/opt/Con Dc/conectdroidcam',
          exists: (p) => p == '/opt/Con Dc/data/linux-webcam-virtual.sh',
        ),
        "sudo bash '/opt/Con Dc/data/linux-webcam-virtual.sh'",
      );
      expect(
        virtualWebcamSetupCommand(
          environment: const {
            'FLATPAK_ID': 'io.github.eduardo_lima_dev.ConectDroidCam',
          },
        ),
        'flatpak run --command=cat io.github.eduardo_lima_dev.ConectDroidCam '
        '/app/share/conectdroidcam/linux-webcam-virtual.sh | sudo bash',
      );
    });

    test('aviso de ffmpeg ausente muda dentro do Flatpak', () {
      expect(ffmpegMissingText(environment: const {}), contains('pacote'));
      expect(
        ffmpegMissingText(environment: const {'FLATPAK_ID': 'x'}),
        contains('Reinstale'),
      );
    });

    testWidgets(
      'núcleo que não carrega mostra o motivo e deixa tentar de novo',
      (tester) async {
        final platform = FakeReceiverPlatform()
          ..initError = StateError('libcdc_ffi.so ausente');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              receiverPlatformProvider.overrideWithValue(platform),
              receiverSettingsStoreProvider.overrideWithValue(
                FakeSettingsStore(),
              ),
            ],
            child: const ConectDroidCamApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('O app não conseguiu iniciar'), findsOneWidget);
        expect(find.textContaining('libcdc_ffi.so'), findsOneWidget);
        expect(find.text('Tentar de novo'), findsOneWidget);
      },
      variant: linux,
    );
  });

  testWidgets(
    'no macOS, o app do computador ainda não existe',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ConectDroidCamApp()));
      await tester.pumpAndSettle();

      expect(find.text('Receptor em desenvolvimento'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
