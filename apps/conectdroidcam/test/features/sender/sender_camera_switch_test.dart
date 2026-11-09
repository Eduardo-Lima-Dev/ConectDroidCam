import 'package:conectdroidcam/features/sender/application/sender_controller.dart';
import 'package:conectdroidcam/features/sender/data/sender_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sender_platform.dart';

void main() {
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
