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

  setUp(() async {
    platform = FakeSenderPlatform()..permissionGranted = true;
    container = ProviderContainer(
      overrides: [senderPlatformProvider.overrideWithValue(platform)],
    );
    await controller().start();
  });

  tearDown(() => container.dispose());

  test('carrega os ajustes da câmera ao abrir a prévia', () {
    expect(state().controls.canZoom, isTrue);
    expect(state().controls.zoomPresets, [0.5, 1.0, 2.0, 5.0]);
  });

  test('zoom fica dentro do que a câmera aceita', () async {
    await controller().setZoom(20);
    expect(state().controls.zoom, 8);
    expect(platform.controlCalls.last, 'zoom 8.0');
  });

  test('vários pedidos de zoom seguidos mandam só o último pendente', () async {
    final a = controller().setZoom(2);
    final b = controller().setZoom(3);
    final c = controller().setZoom(4);
    await Future.wait([a, b, c]);
    expect(platform.controlCalls, ['zoom 2.0', 'zoom 4.0']);
    expect(state().controls.zoom, 4);
  });

  test('tocar para focar trava o foco e o botão volta ao automático', () async {
    expect(await controller().focusAt(0.25, 0.75), isTrue);
    expect(state().controls.focusLocked, isTrue);
    expect(platform.controlCalls.last, 'focus 0.25 0.75');

    await controller().focusAuto();
    expect(state().controls.focusLocked, isFalse);
  });

  test('exposição, travas e lanterna chegam à câmera', () async {
    await controller().setExposure(6);
    await controller().setAeLock(true);
    await controller().setAwbLock(true);
    await controller().setTorch(true);

    final c = state().controls;
    expect(c.exposure, 6);
    expect(exposureLabel(c.exposureEv), '+1,0 EV');
    expect(c.aeLock && c.awbLock && c.torch, isTrue);
  });

  test('ajuste recusado pela câmera vira aviso', () async {
    platform.controlsError = const SenderException('a câmera recusou');
    await controller().setTorch(true);
    expect(state().notice, 'a câmera recusou');
    expect(state().controls.torch, isFalse);
  });

  test('sem a câmera aberta, nenhum ajuste é enviado', () async {
    platform.emit(const ErrorEvent('a câmera parou'));
    await Future<void>.delayed(Duration.zero);
    await controller().setTorch(true);
    await controller().setZoom(2);
    expect(platform.controlCalls, isEmpty);
  });

  test('textos do zoom e da exposição', () {
    expect(zoomLabel(1), '1×');
    expect(zoomLabel(0.5), '0,5×');
    expect(zoomLabel(2.04), '2×');
    expect(exposureLabel(0), '0 EV');
    expect(exposureLabel(-0.667), '−0,7 EV');
  });
}
