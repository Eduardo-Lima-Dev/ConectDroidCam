import 'package:conectdroidcam/features/sender/application/sender_controller.dart';
import 'package:conectdroidcam/features/sender/data/sender_platform.dart';
import 'package:conectdroidcam/features/sender/domain/sender_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sender_platform.dart';

void main() {
  group('comandos do computador', remoteTests);

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
