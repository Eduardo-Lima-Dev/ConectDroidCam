import 'package:conectdroidcam/features/receiver/application/receiver_controller.dart';
import 'package:conectdroidcam/features/receiver/domain/receiver_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_receiver_platform.dart';

PhoneCapabilities caps({
  bool streaming = false,
  bool front = false,
  bool canSwitch = true,
}) => PhoneCapabilities(
  modes: const [
    PhoneMode(width: 1280, height: 720, available: true),
    PhoneMode(width: 1920, height: 1080, available: true),
    PhoneMode(
      width: 2560,
      height: 1440,
      available: false,
      reason: 'sem codificador',
    ),
  ],
  fpsOptions: const [15, 24, 30],
  front: front,
  canSwitch: canSwitch,
  streaming: streaming,
);

void main() {
  late FakeReceiverPlatform platform;
  late ProviderContainer container;

  ReceiverController controller() =>
      container.read(receiverControllerProvider.notifier);
  ReceiverState state() => container.read(receiverControllerProvider);
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    platform = FakeReceiverPlatform();
    container = ProviderContainer(
      overrides: [
        receiverPlatformProvider.overrideWithValue(platform),
        receiverSettingsStoreProvider.overrideWithValue(FakeSettingsStore()),
      ],
    );
    addTearDown(container.dispose);
    container.listen(receiverControllerProvider, (_, _) {});
    await controller().start();
    await controller().connect('192.168.0.7:47821');
    platform.send(const HelloUpdate(deviceName: 'Pixel', platform: 'android'));
    platform.send(CapabilitiesUpdate(caps()));
    await tick();
  });

  test('ao conectar, escolhe Full HD a 30 FPS e o celular está parado', () {
    expect(state().capabilities, isNotNull);
    expect(state().phoneStreaming, isFalse);
    expect(state().remoteMode!.label, '1920×1080');
    expect(state().remoteFps, 30);
  });

  test('iniciar manda o tamanho e o FPS escolhidos', () async {
    await controller().selectRemoteMode(state().capabilities!.modes.first);
    await controller().selectRemoteFps(24);
    await controller().startPhoneStream();
    expect(platform.commands, ['start 1280x720@24']);
  });

  test('resolução indisponível não pode ser escolhida', () async {
    await controller().selectRemoteMode(state().capabilities!.modes.last);
    expect(state().remoteMode!.label, '1920×1080');
    expect(platform.commands, isEmpty);
  });

  test('parar manda o comando e a tela espera a resposta do celular', () async {
    platform.send(CapabilitiesUpdate(caps(streaming: true)));
    await tick();
    expect(state().phoneStreaming, isTrue);

    await controller().stopPhoneStream();
    expect(platform.commands, ['stop']);

    platform.send(CapabilitiesUpdate(caps()));
    await tick();
    expect(state().phoneStreaming, isFalse);
    expect(state().incoming, isNull);
  });

  test('com o celular transmitindo, trocar o FPS vale na hora', () async {
    platform.send(CapabilitiesUpdate(caps(streaming: true)));
    await tick();
    await controller().selectRemoteFps(15);
    expect(platform.commands, ['fps 15']);
  });

  test(
    'com o celular transmitindo, trocar a resolução para e recomeça',
    () async {
      platform.send(CapabilitiesUpdate(caps(streaming: true)));
      await tick();
      await controller().selectRemoteMode(state().capabilities!.modes.first);
      expect(platform.commands, ['stop', 'start 1280x720@30']);
    },
  );

  test('trocar de câmera alterna a partir do estado informado', () async {
    await controller().switchPhoneCamera();
    expect(platform.commands, ['camera front']);

    platform.send(CapabilitiesUpdate(caps(front: true)));
    await tick();
    await controller().switchPhoneCamera();
    expect(platform.commands.last, 'camera back');
  });

  test('sem as duas câmeras, trocar não faz nada', () async {
    platform.send(CapabilitiesUpdate(caps(canSwitch: false)));
    await tick();
    await controller().switchPhoneCamera();
    expect(platform.commands, isEmpty);
  });

  test('falha ao enviar o comando aparece para o usuário', () async {
    platform.commandError = 'sem sessão';
    await controller().startPhoneStream();
    expect(state().error, contains('sem sessão'));
  });

  test(
    'se o celular já transmite, a escolha mostra o que ele entrega',
    () async {
      platform.send(CapabilitiesUpdate(caps(streaming: true)));
      platform.send(
        const ProfileUpdate(
          IncomingVideo(
            width: 1280,
            height: 720,
            fps: 15,
            bitrateKbps: 3000,
            rotation: 0,
          ),
        ),
      );
      await tick();
      expect(state().remoteMode!.label, '1280×720');
      expect(state().remoteFps, 15);
    },
  );

  test('ao desconectar, o controle some', () async {
    await controller().disconnect();
    await tick();
    expect(state().capabilities, isNull);
  });
}
