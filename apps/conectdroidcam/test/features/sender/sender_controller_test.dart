import 'package:conectdroidcam/features/sender/application/sender_controller.dart';
import 'package:conectdroidcam/features/sender/data/sender_platform.dart';
import 'package:conectdroidcam/features/sender/domain/sender_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sender_platform.dart';

void main() {
  late FakeSenderPlatform platform;
  late ProviderContainer container;

  SenderController controller() =>
      container.read(senderControllerProvider.notifier);
  SenderState state() => container.read(senderControllerProvider);

  setUp(() {
    platform = FakeSenderPlatform();
    container = ProviderContainer(
      overrides: [senderPlatformProvider.overrideWithValue(platform)],
    );
    addTearDown(container.dispose);
    // Mantém o provider vivo durante o teste.
    container.listen(senderControllerProvider, (_, _) {});
  });

  group('permissão e câmera', () {
    test('pede a permissão, abre a prévia e escolhe a HD', () async {
      await controller().start();

      expect(platform.permissionRequests, 1);
      expect(state().phase, SenderPhase.ready);
      expect(state().preview?.textureId, 1);
      expect(state().selected, VideoMode.hd);
      expect(state().busy, isFalse);
    });

    test('não pede a permissão de novo se ela já foi concedida', () async {
      platform.permissionGranted = true;

      await controller().start();

      expect(platform.permissionRequests, 0);
      expect(state().phase, SenderPhase.ready);
    });

    test('permissão negada não abre a câmera', () async {
      platform.grantOnRequest = false;

      await controller().start();

      expect(state().phase, SenderPhase.permissionDenied);
      expect(platform.previewStarts, 0);
      expect(state().busy, isFalse);
    });

    test('falha ao abrir a câmera vira erro com a mensagem', () async {
      platform.permissionGranted = true;
      platform.startPreviewError = const SenderException('câmera em uso');

      await controller().start();

      expect(state().phase, SenderPhase.failed);
      expect(state().error, 'câmera em uso');
    });

    test(
      'o endereço mostrado é o da rede local, não o dos dados móveis',
      () async {
        await controller().start();

        expect(state().lanAddress?.address, '192.168.0.7');
      },
    );

    test('girar a tela reorienta a prévia sem reiniciar a câmera', () async {
      await controller().start();
      expect(state().preview?.displayRotation, 0);

      platform.emit(const RotationEvent(1));
      await Future<void>.delayed(Duration.zero);

      expect(state().preview?.displayRotation, 1);
      expect(state().preview?.quarterTurns, 3);
      expect(state().preview?.textureId, 1);
      expect(platform.previewStarts, 1);
    });

    test('rotação sem prévia aberta é ignorada', () async {
      platform.emit(const RotationEvent(1));
      await Future<void>.delayed(Duration.zero);

      expect(state().preview, isNull);
    });
  });

  group('resoluções do aparelho', () {
    test(
      'as três principais aparecem sempre, na ordem, com o motivo',
      () async {
        await controller().start();

        final main = state().capabilities.mainModes;
        expect(main.map((m) => m.mode), VideoMode.main);
        expect(main.map((m) => m.available), [true, true, false]);
        expect(main.last.reason, contains('2560×1440'));
      },
    );

    test(
      'uma principal que a câmera nem oferece aparece indisponível',
      () async {
        platform.capabilities = const SenderCapabilities(
          fpsOptions: [30],
          modes: [ModeAvailability(mode: VideoMode.hd, available: true)],
        );

        await controller().start();

        final main = state().capabilities.mainModes;
        expect(main, hasLength(3));
        expect(main[1].available, isFalse);
        expect(main[1].reason, 'a câmera não oferece 1920×1080');
      },
    );

    test(
      'as extras são só as disponíveis e não principais, em ordem',
      () async {
        await controller().start();

        final extras = state().capabilities.extraModes.map((m) => m.mode);
        expect(extras, [
          const VideoMode(1920, 1440),
          VideoMode.uhd,
          const VideoMode(4000, 2256),
        ]);
      },
    );

    test('resolução indisponível não pode ser escolhida', () async {
      await controller().start();

      controller().select(VideoMode.qhd);
      expect(state().selected, VideoMode.hd);

      controller().select(VideoMode.fullHd);
      expect(state().selected, VideoMode.fullHd);
    });

    test('dá para escolher uma resolução extra', () async {
      await controller().start();

      controller().select(VideoMode.uhd);

      expect(state().selected, VideoMode.uhd);
      expect(state().canStart, isTrue);
    });

    test('se a HD sumir, escolhe a primeira principal disponível', () async {
      platform.capabilities = const SenderCapabilities(
        fpsOptions: [30],
        modes: [
          ModeAvailability(mode: VideoMode.hd, available: false, reason: 'x'),
          ModeAvailability(mode: VideoMode.fullHd, available: true),
        ],
      );

      await controller().start();

      expect(state().selected, VideoMode.fullHd);
    });

    test('os nomes comerciais mostram sempre a resolução', () {
      expect(VideoMode.hd.label, 'HD (1280×720)');
      expect(VideoMode.fullHd.label, 'Full HD (1920×1080)');
      expect(VideoMode.qhd.label, '2K (2560×1440)');
      expect(VideoMode.uhd.label, '4K (3840×2160)');
      expect(const VideoMode(1920, 1440).label, '1920×1440');
    });
  });

  group('FPS', () {
    test('o padrão é 30 e as opções vêm do aparelho', () async {
      await controller().start();

      expect(state().selectedFps, 30);
      expect(state().capabilities.fpsFor(VideoMode.hd), [15, 20, 30]);
    });

    test(
      'resolução que só chega a 20 FPS limita as opções e ajusta o FPS',
      () async {
        await controller().start();
        expect(state().selectedFps, 30);

        controller().select(const VideoMode(4000, 2256));

        expect(state().capabilities.fpsFor(state().selected), [15, 20]);
        expect(state().selectedFps, 20);
      },
    );

    test('trocar o FPS antes de transmitir não chama o nativo', () async {
      await controller().start();

      await controller().selectFps(15);

      expect(state().selectedFps, 15);
      expect(platform.setFpsCalls, isEmpty);
    });

    test(
      'trocar o FPS durante a transmissão aplica na hora, sem reiniciar',
      () async {
        await controller().start();
        await controller().startStreaming();

        await controller().selectFps(20);

        expect(platform.setFpsCalls, [20]);
        expect(state().selectedFps, 20);
        expect(state().isStreaming, isTrue);
        expect(platform.streamStarts, 1);
        expect(platform.streamStops, 0);
      },
    );

    test('FPS que a resolução não sustenta é ignorado', () async {
      await controller().start();
      controller().select(const VideoMode(4000, 2256));

      await controller().selectFps(30);

      expect(state().selectedFps, 20);
    });

    test('se o aparelho recusar o FPS, avisa e mantém a transmissão', () async {
      await controller().start();
      await controller().startStreaming();
      platform.setFpsError = const SenderException('a câmera recusou 15 FPS');

      await controller().selectFps(15);

      expect(state().isStreaming, isTrue);
      expect(state().selectedFps, 30);
      expect(state().notice, 'a câmera recusou 15 FPS');
      expect(state().busy, isFalse);
    });
  });

  group('transmissão', () {
    test('inicia com a resolução e o FPS escolhidos', () async {
      await controller().start();
      controller().select(VideoMode.fullHd);
      await controller().selectFps(20);

      await controller().startStreaming();

      expect(state().phase, SenderPhase.streaming);
      expect(state().stream?.width, 1920);
      expect(state().stream?.height, 1080);
      expect(state().stream?.port, 47821);
      expect(platform.lastStreamedMode, VideoMode.fullHd);
      expect(platform.lastStreamedFps, 20);
    });

    test('não troca de resolução durante a transmissão', () async {
      await controller().start();
      await controller().startStreaming();

      controller().select(VideoMode.fullHd);

      expect(state().selected, VideoMode.hd);
    });

    test('eventos de cliente e estatísticas atualizam o estado', () async {
      await controller().start();
      await controller().startStreaming();

      platform.emit(
        const ClientEvent(connected: true, peer: '192.168.0.15:5544'),
      );
      platform.emit(const StatsEvent(fps: 29.8, bitrateKbps: 2950, dropped: 3));
      await Future<void>.delayed(Duration.zero);

      expect(state().clientPeer, '192.168.0.15:5544');
      expect(state().measuredFps, 29.8);
      expect(state().bitrateKbps, 2950);
      expect(state().dropped, 3);

      platform.emit(const ClientEvent(connected: false));
      await Future<void>.delayed(Duration.zero);
      expect(state().clientPeer, isNull);
      expect(state().isStreaming, isTrue);
    });

    test('erro do código nativo derruba a transmissão na interface', () async {
      await controller().start();
      await controller().startStreaming();

      platform.emit(const ErrorEvent('A câmera foi desconectada.'));
      await Future<void>.delayed(Duration.zero);

      expect(state().phase, SenderPhase.failed);
      expect(state().stream, isNull);
      expect(state().preview, isNull);
      expect(state().error, 'A câmera foi desconectada.');
    });

    test('parar a transmissão volta ao estado pronto', () async {
      await controller().start();
      await controller().startStreaming();

      await controller().stopStreaming();

      expect(state().phase, SenderPhase.ready);
      expect(state().stream, isNull);
      expect(platform.streamStops, 1);
    });

    test('falha ao iniciar a transmissão mostra o motivo', () async {
      await controller().start();
      platform.startStreamingError = const SenderException('porta em uso');

      await controller().startStreaming();

      expect(state().phase, SenderPhase.failed);
      expect(state().error, 'porta em uso');
    });
  });

  group('anúncio na rede', () {
    test('mostra o nome com que o celular aparece para o computador', () async {
      await controller().start();
      await controller().startStreaming();

      platform.emit(
        const DiscoveryEvent(registered: true, name: 'ConectDroidCam Pixel'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(state().visibleAs, 'ConectDroidCam Pixel');
      expect(state().visibilityError, isNull);
    });

    test(
      'se o anúncio falhar, guarda o motivo e o app segue funcionando',
      () async {
        await controller().start();
        await controller().startStreaming();

        platform.emit(
          const DiscoveryEvent(registered: false, error: 'código 3'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(state().visibleAs, isNull);
        expect(state().visibilityError, 'código 3');
        expect(state().isStreaming, isTrue);
      },
    );

    test('ao parar a transmissão o celular continua visível na rede', () async {
      await controller().start();
      await controller().startStreaming();
      platform.emit(const DiscoveryEvent(registered: true, name: 'X'));
      await Future<void>.delayed(Duration.zero);

      await controller().stopStreaming();

      expect(state().visibleAs, 'X');
    });
  });
}
