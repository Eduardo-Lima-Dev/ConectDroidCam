import 'package:conectdroidcam/features/sender/application/sender_controller.dart';
import 'package:conectdroidcam/features/sender/data/sender_platform.dart';
import 'package:conectdroidcam/features/sender/domain/sender_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sender_platform.dart';

void main() {
  group('comandos do computador', remoteTests);
  group('pareamento', pairingTests);

  late FakeSenderPlatform platform;
  late ProviderContainer container;

  Future<SenderController> ready() async {
    platform = FakeSenderPlatform()..permissionGranted = true;
    container = ProviderContainer(
      overrides: [senderPlatformProvider.overrideWithValue(platform)],
    );
    addTearDown(container.dispose);
    final controller = container.read(senderControllerProvider.notifier);
    await controller.start();
    return controller;
  }

  SenderState state() => container.read(senderControllerProvider);

  Future<void> pausa() => Future<void>.delayed(Duration.zero);

  test(
    'câmera perdida em segundo plano volta sozinha ao reabrir o app',
    () async {
      final controller = await ready();
      final aberturas = platform.previewStarts;
      platform.emit(const ErrorEvent('a câmera parou', recoverable: true));
      await pausa();
      expect(state().phase, SenderPhase.failed);

      await controller.onResumed();

      expect(state().phase, SenderPhase.ready);
      expect(platform.previewStarts, aberturas + 1);
    },
  );

  test('erro de câmera sem volta não reinicia ao reabrir o app', () async {
    final controller = await ready();
    platform.emit(const ErrorEvent('a câmera parou de responder'));
    await pausa();

    await controller.onResumed();

    expect(state().phase, SenderPhase.failed);
  });

  test('o nome do computador pareado acompanha a conexão', () async {
    await ready();
    platform.emit(
      const ClientEvent(connected: true, peer: '10.0.0.5:5000', name: 'meu-pc'),
    );
    await pausa();
    expect(state().clientName, 'meu-pc');

    platform.emit(const ClientEvent(connected: false));
    await pausa();
    expect(state().clientName, isNull);
  });

  test('alterna entre traseira e frontal e reflete na prévia', () async {
    final controller = await ready();
    expect(state().preview!.isFront, isFalse);

    await controller.switchCamera();
    expect(state().preview!.isFront, isTrue);
    expect(platform.switchCalls, [true]);

    await controller.switchCamera();
    expect(state().preview!.isFront, isFalse);
    expect(platform.switchCalls, [true, false]);
    expect(state().busy, isFalse);
  });

  test('sem as duas câmeras, não faz nada', () async {
    platform = FakeSenderPlatform()
      ..permissionGranted = true
      ..canSwitch = false;
    container = ProviderContainer(
      overrides: [senderPlatformProvider.overrideWithValue(platform)],
    );
    addTearDown(container.dispose);
    final controller = container.read(senderControllerProvider.notifier);
    await controller.start();
    await controller.switchCamera();
    expect(platform.switchCalls, isEmpty);
  });

  test(
    'com a transmissão ligada, continua transmitindo e mantém a resolução',
    () async {
      final controller = await ready();
      await controller.startStreaming();
      final mode = state().selected;
      await controller.switchCamera();
      expect(state().isStreaming, isTrue);
      expect(state().selected, mode);
      expect(state().preview!.isFront, isTrue);
      expect(platform.streamStops, 0);
    },
  );

  test(
    'recusa da câmera nova vira aviso e não derruba a transmissão',
    () async {
      final controller = await ready();
      await controller.startStreaming();
      platform.switchCameraError = const SenderException(
        'A câmera frontal não oferece 1920×1080.',
      );
      await controller.switchCamera();
      expect(state().isStreaming, isTrue);
      expect(state().notice, contains('frontal'));
      expect(state().preview!.isFront, isFalse);
      expect(state().busy, isFalse);
    },
  );
}

void remoteTests() {
  late FakeSenderPlatform platform;
  late ProviderContainer container;

  SenderState state() => container.read(senderControllerProvider);
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    platform = FakeSenderPlatform()..permissionGranted = true;
    container = ProviderContainer(
      overrides: [senderPlatformProvider.overrideWithValue(platform)],
    );
    addTearDown(container.dispose);
    await container.read(senderControllerProvider.notifier).start();
  });

  test('o computador liga a transmissão e o celular acompanha', () async {
    platform.emit(
      const RemoteStreamEvent(
        streaming: true,
        stream: StreamInfo(
          mode: VideoMode(1280, 720),
          fps: 24,
          bitrateKbps: 3000,
          port: 47821,
        ),
      ),
    );
    await tick();
    expect(state().isStreaming, isTrue);
    expect(state().selected, const VideoMode(1280, 720));
    expect(state().selectedFps, 24);
  });

  test('o computador desliga e o celular volta a ficar pronto', () async {
    platform.emit(
      const RemoteStreamEvent(
        streaming: true,
        stream: StreamInfo(
          mode: VideoMode(1280, 720),
          fps: 30,
          bitrateKbps: 3000,
          port: 47821,
        ),
      ),
    );
    await tick();
    platform.emit(const RemoteStreamEvent(streaming: false));
    await tick();
    expect(state().phase, SenderPhase.ready);
    expect(state().stream, isNull);
  });

  test('o computador troca a câmera e a prévia acompanha', () async {
    platform.emit(
      const CameraChangedEvent(
        PreviewInfo(
          textureId: 1,
          width: 1280,
          height: 720,
          isFront: true,
          canSwitch: true,
        ),
      ),
    );
    await tick();
    expect(state().preview!.isFront, isTrue);
  });
}

void pairingTests() {
  late FakeSenderPlatform platform;
  late ProviderContainer container;

  SenderState state() => container.read(senderControllerProvider);
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    platform = FakeSenderPlatform()..permissionGranted = true;
    container = ProviderContainer(
      overrides: [senderPlatformProvider.overrideWithValue(platform)],
    );
    addTearDown(container.dispose);
    await container.read(senderControllerProvider.notifier).start();
  });

  test('um computador novo pede pareamento e o código aparece', () async {
    platform.emit(
      const PairingRequestEvent(code: '482913', computer: 'meu-pc'),
    );
    await tick();
    expect(state().pairing!.code, '482913');
    expect(state().pairing!.computer, 'meu-pc');
  });

  test('confirmar manda a resposta e fecha o pedido', () async {
    platform.emit(
      const PairingRequestEvent(code: '482913', computer: 'meu-pc'),
    );
    await tick();
    await container
        .read(senderControllerProvider.notifier)
        .confirmPairing(true);
    expect(platform.pairingAnswers, [true]);
    expect(state().pairing, isNull);
  });

  test('recusar manda a resposta contrária', () async {
    platform.emit(
      const PairingRequestEvent(code: '482913', computer: 'meu-pc'),
    );
    await tick();
    await container
        .read(senderControllerProvider.notifier)
        .confirmPairing(false);
    expect(platform.pairingAnswers, [false]);
  });

  test('pareamento concluído atualiza a lista e avisa', () async {
    platform.paired = [
      PairedComputer(
        fingerprint: 'ab' * 32,
        name: 'meu-pc',
        since: DateTime(2026),
      ),
    ];
    platform.emit(const PairingEndedEvent(paired: true, computer: 'meu-pc'));
    await tick();
    await tick();
    expect(state().pairing, isNull);
    expect(state().pairedComputers.single.name, 'meu-pc');
    expect(state().success, contains('meu-pc'));
    expect(state().notice, isNull);
  });

  test(
    'pareamento que não deu certo mostra o motivo e fecha o pedido',
    () async {
      platform.emit(
        const PairingRequestEvent(code: '482913', computer: 'meu-pc'),
      );
      await tick();
      platform.emit(
        const PairingEndedEvent(
          paired: false,
          computer: 'meu-pc',
          reason: 'O pareamento expirou',
        ),
      );
      await tick();
      expect(state().pairing, isNull);
      expect(state().notice, contains('expirou'));
    },
  );

  test('remover o pareamento revoga e atualiza a lista', () async {
    platform.paired = [
      PairedComputer(
        fingerprint: 'cd' * 32,
        name: 'meu-pc',
        since: DateTime(2026),
      ),
    ];
    final controller = container.read(senderControllerProvider.notifier);
    await controller.start();
    await controller.unpair('cd' * 32);
    expect(platform.unpaired, ['cd' * 32]);
    expect(state().pairedComputers, isEmpty);
  });
}
