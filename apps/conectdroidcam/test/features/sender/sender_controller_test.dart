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

  test('pede a permissão, abre a prévia e escolhe o primeiro perfil', () async {
    await controller().start();

    expect(platform.permissionRequests, 1);
    expect(state().phase, SenderPhase.ready);
    expect(state().preview?.textureId, 1);
    expect(state().selected, VideoProfile.hd);
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

  test('perfil indisponível não pode ser escolhido', () async {
    await controller().start();

    controller().select(VideoProfile.qhd);
    expect(state().selected, VideoProfile.hd);

    controller().select(VideoProfile.fullHd);
    expect(state().selected, VideoProfile.fullHd);
  });

  test(
    'o endereço mostrado é o da rede local, não o dos dados móveis',
    () async {
      await controller().start();

      expect(state().lanAddress?.address, '192.168.0.7');
    },
  );

  test('inicia a transmissão com o perfil escolhido', () async {
    await controller().start();
    controller().select(VideoProfile.fullHd);

    await controller().startStreaming();

    expect(state().phase, SenderPhase.streaming);
    expect(state().stream?.width, 1920);
    expect(state().stream?.height, 1080);
    expect(state().stream?.port, 47821);
    expect(platform.streamStarts, 1);
  });

  test('não troca de perfil durante a transmissão', () async {
    await controller().start();
    await controller().startStreaming();

    controller().select(VideoProfile.fullHd);

    expect(state().selected, VideoProfile.hd);
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
    expect(state().fps, 29.8);
    expect(state().bitrateKbps, 2950);
    expect(state().dropped, 3);

    platform.emit(const ClientEvent(connected: false));
    await Future<void>.delayed(Duration.zero);
    expect(state().clientPeer, isNull);
    expect(state().isStreaming, isTrue);
  });

  test(
    'erro vindo do código nativo derruba a transmissão na interface',
    () async {
      await controller().start();
      await controller().startStreaming();

      platform.emit(const ErrorEvent('A câmera foi desconectada.'));
      await Future<void>.delayed(Duration.zero);

      expect(state().phase, SenderPhase.failed);
      expect(state().stream, isNull);
      expect(state().preview, isNull);
      expect(state().error, 'A câmera foi desconectada.');
    },
  );

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
}
