import 'package:conectdroidcam/features/receiver/application/receiver_controller.dart';
import 'package:conectdroidcam/features/receiver/domain/receiver_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_receiver_platform.dart';

const hello = HelloUpdate(deviceName: 'Pixel', platform: 'android');
const saida = OutputUpdate(
  OutgoingVideo(
    width: 1080,
    height: 1920,
    rotation: 90,
    device: '/dev/video11',
  ),
);

PhoneCapabilities caps({bool streaming = false}) => PhoneCapabilities(
  modes: const [
    PhoneMode(width: 1280, height: 720, available: true),
    PhoneMode(width: 1920, height: 1080, available: true),
  ],
  fpsOptions: const [15, 30],
  front: false,
  canSwitch: true,
  streaming: streaming,
);

void main() {
  late FakeReceiverPlatform platform;
  late ProviderContainer container;

  ReceiverController controller() =>
      container.read(receiverControllerProvider.notifier);
  ReceiverState state() => container.read(receiverControllerProvider);

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> conectado({bool streaming = true}) async {
    await controller().start();
    await controller().connect('192.168.0.7:47821');
    platform.send(hello);
    platform.send(CapabilitiesUpdate(caps(streaming: streaming)));
    platform.send(saida);
    await settle();
    expect(state().phase, ReceiverPhase.connected);
  }

  setUp(() {
    platform = FakeReceiverPlatform();
    container = ProviderContainer(
      overrides: [
        receiverPlatformProvider.overrideWithValue(platform),
        receiverSettingsStoreProvider.overrideWithValue(FakeSettingsStore()),
        reconnectDelaysProvider.overrideWithValue(
          List.filled(3, Duration.zero),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(receiverControllerProvider, (_, _) {});
  });

  test(
    'queda depois de conectado reconecta sozinho e volta a transmitir',
    () async {
      await conectado();
      platform.scriptedConnect = (_) => [hello, CapabilitiesUpdate(caps())];

      platform.send(const FailedUpdate('conexão perdida'));
      await settle();

      expect(state().phase, ReceiverPhase.connected);
      expect(platform.connects, 2);
      expect(platform.lastAddress, '192.168.0.7:47821');
      expect(platform.idleFeed, ['start /dev/video11 1080x1920', 'stop']);
      expect(platform.commands, ['start 1920x1080@30']);
    },
  );

  test('se o celular continuou transmitindo, não pede de novo', () async {
    await conectado();
    platform.scriptedConnect = (_) => [
      hello,
      CapabilitiesUpdate(caps(streaming: true)),
    ];
    platform.send(const EndedUpdate());
    await settle();
    expect(state().phase, ReceiverPhase.connected);
    expect(platform.commands, isEmpty);
  });

  test('tenta de novo enquanto falha e para quando volta', () async {
    await conectado(streaming: false);
    platform.scriptedConnect = (n) => n < 4
        ? [const FailedUpdate('recusada')]
        : [hello, CapabilitiesUpdate(caps())];
    platform.send(const FailedUpdate('conexão perdida'));
    await settle();
    expect(state().phase, ReceiverPhase.connected);
    expect(platform.connects, 4);
    expect(platform.idleFeed.last, 'stop');
    expect(platform.commands, isEmpty);
  });

  test('desiste depois de todas as tentativas e explica', () async {
    await conectado();
    platform.scriptedConnect = (_) => [const FailedUpdate('recusada')];
    platform.send(const FailedUpdate('conexão perdida'));
    await settle();
    expect(state().phase, ReceiverPhase.idle);
    expect(state().error, contains('caiu e não voltou'));
    expect(platform.connects, 4);
    expect(platform.idleFeed.last, 'stop');
  });

  test('desconectar não reconecta', () async {
    await conectado();
    await controller().disconnect();
    await settle();
    expect(state().phase, ReceiverPhase.idle);
    expect(platform.connects, 1);
    expect(platform.idleFeed, isEmpty);
  });

  test('falha antes de conectar não vira reconexão', () async {
    await controller().start();
    await controller().connect('192.168.0.7:47821');
    platform.send(const FailedUpdate('o certificado deste celular mudou'));
    await settle();
    expect(state().phase, ReceiverPhase.idle);
    expect(state().error, contains('certificado'));
    expect(platform.connects, 1);
  });

  test('pareamento recusado não vira reconexão', () async {
    await controller().start();
    await controller().connect('192.168.0.7:47821');
    platform.send(hello);
    platform.send(const PairingDeniedUpdate('recusado no celular'));
    platform.send(const EndedUpdate());
    await settle();
    expect(state().phase, ReceiverPhase.idle);
    expect(platform.connects, 1);
  });

  test(
    'cancelar durante a reconexão para tudo e tira a imagem neutra',
    () async {
      container.updateOverrides([
        receiverPlatformProvider.overrideWithValue(platform),
        receiverSettingsStoreProvider.overrideWithValue(FakeSettingsStore()),
        reconnectDelaysProvider.overrideWithValue(
          List.filled(3, const Duration(seconds: 30)),
        ),
      ]);
      await conectado();
      platform.send(const FailedUpdate('conexão perdida'));
      await settle();
      expect(state().phase, ReceiverPhase.reconnecting);
      expect(platform.idleFeed, ['start /dev/video11 1080x1920']);

      await controller().disconnect();
      await settle();
      expect(state().phase, ReceiverPhase.idle);
      expect(platform.idleFeed.last, 'stop');
      expect(platform.connects, 1);
    },
  );
}
