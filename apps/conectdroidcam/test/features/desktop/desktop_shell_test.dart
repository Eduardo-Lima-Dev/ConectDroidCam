import 'dart:async';
import 'dart:typed_data';

import 'package:conectdroidcam/features/desktop/application/desktop_shell.dart';
import 'package:conectdroidcam/features/desktop/data/desktop_window.dart';
import 'package:conectdroidcam/features/desktop/data/tray_platform.dart';
import 'package:conectdroidcam/features/desktop/domain/desktop_models.dart';
import 'package:conectdroidcam/features/receiver/application/receiver_controller.dart';
import 'package:conectdroidcam/features/receiver/domain/receiver_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../receiver/fake_receiver_platform.dart';

class FakeWindow implements DesktopWindow {
  final calls = <String>[];
  final close = StreamController<void>.broadcast();

  @override
  Future<void> setInterceptClose(bool value) async =>
      calls.add('intercept $value');
  @override
  Future<void> show() async => calls.add('show');
  @override
  Future<void> hide() async => calls.add('hide');
  @override
  Future<void> quit() async => calls.add('quit');
  @override
  Stream<void> get closeRequests => close.stream;
}

class FakeTray implements TrayPlatform {
  final events = StreamController<TrayMessage>.broadcast();
  final updates = <TrayMenuState>[];
  bool? sandboxed;
  int stops = 0;

  @override
  Stream<TrayMessage> start({
    required Uint8List rgba,
    required int width,
    required int height,
    required bool sandboxed,
  }) {
    this.sandboxed = sandboxed;
    return events.stream;
  }

  @override
  Future<void> update(TrayMenuState state) async => updates.add(state);

  @override
  Future<void> stop() async => stops++;
}

void main() {
  late FakeReceiverPlatform platform;
  late FakeWindow window;
  late FakeTray tray;
  late ProviderContainer container;

  DesktopShell shell() => container.read(desktopShellProvider.notifier);
  DesktopShellState shellState() => container.read(desktopShellProvider);
  ReceiverState receiver() => container.read(receiverControllerProvider);
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    platform = FakeReceiverPlatform();
    window = FakeWindow();
    tray = FakeTray();
    container = ProviderContainer(
      overrides: [
        receiverPlatformProvider.overrideWithValue(platform),
        receiverSettingsStoreProvider.overrideWithValue(FakeSettingsStore()),
        desktopWindowProvider.overrideWithValue(window),
        trayPlatformProvider.overrideWithValue(tray),
        sandboxedProvider.overrideWithValue(true),
        trayIconLoaderProvider.overrideWithValue(
          () async => (rgba: Uint8List(4), width: 1, height: 1),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(desktopShellProvider, (_, _) {});
    await container.read(receiverControllerProvider.notifier).start();
    await shell().start();
  });

  Future<void> conectar() async {
    await container
        .read(receiverControllerProvider.notifier)
        .connect('192.168.0.7:47821', name: 'Pixel');
    platform.send(const HelloUpdate(deviceName: 'Pixel', platform: 'android'));
    await tick();
  }

  test(
    'assume o fechamento da janela e avisa a bandeja que está no Flatpak',
    () {
      expect(window.calls, ['intercept true']);
      expect(tray.sandboxed, isTrue);
    },
  );

  test('com a bandeja, fechar a janela só esconde', () async {
    tray.events.add(const TrayMessage(TrayCommand.ready));
    await tick();
    expect(shellState().trayAvailable, isTrue);

    window.close.add(null);
    await tick();
    expect(window.calls.last, 'hide');
  });

  test('a bandeja acompanha o estado da conexão', () async {
    tray.events.add(const TrayMessage(TrayCommand.ready));
    await tick();
    expect(tray.updates.last.statusLine, 'Nenhum celular conectado');

    await conectar();
    expect(tray.updates.last.statusLine, 'Conectado a Pixel');
    expect(tray.updates.last.connected, isTrue);
  });

  test('sem bandeja e sem celular, fechar a janela encerra o app', () async {
    tray.events.add(const TrayMessage(TrayCommand.unavailable, 'sem watcher'));
    await tick();
    expect(shellState().trayError, 'sem watcher');

    window.close.add(null);
    await tick();
    expect(window.calls.last, 'quit');
  });

  test(
    'sem bandeja e com celular conectado, pergunta antes de fechar',
    () async {
      tray.events.add(const TrayMessage(TrayCommand.unavailable));
      await conectar();

      window.close.add(null);
      await tick();
      expect(shellState().closePrompt, 1);
      expect(window.calls, isNot(contains('quit')));

      await shell().keepRunningHidden();
      expect(window.calls.last, 'hide');
    },
  );

  test('o menu da bandeja mostra a janela, desconecta e sai', () async {
    tray.events.add(const TrayMessage(TrayCommand.ready));
    await conectar();

    tray.events.add(const TrayMessage(TrayCommand.showWindow));
    await tick();
    expect(window.calls.last, 'show');

    final antes = platform.disconnects;
    tray.events.add(const TrayMessage(TrayCommand.quit));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    platform.send(const EndedUpdate());
    await platform.endSession();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(platform.disconnects, antes + 1);
    expect(tray.stops, 1);
    expect(window.calls.last, 'quit');
    expect(receiver().isBusy, isFalse);
  });

  group('texto da bandeja', () {
    test('mostra quantos celulares há na rede quando nada está conectado', () {
      final s = const ReceiverState(phase: ReceiverPhase.idle).copyWith(
        phones: const [
          Phone(id: 'a', name: 'A', address: '1.1.1.1:1'),
          Phone(id: 'b', name: 'B', address: '1.1.1.2:1'),
        ],
      );
      expect(trayMenuFor(s).statusLine, '2 celulares encontrados na rede');
      expect(trayMenuFor(s).canStream, isFalse);
    });

    test('reconectando', () {
      final s = const ReceiverState(
        phase: ReceiverPhase.reconnecting,
        phoneName: 'Pixel',
      );
      expect(trayMenuFor(s).statusLine, 'Reconectando a Pixel…');
      expect(trayMenuFor(s).connected, isTrue);
    });
  });
}
