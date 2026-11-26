import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../receiver/application/receiver_controller.dart';
import '../data/desktop_window.dart';
import '../data/tray_platform.dart';
import '../domain/desktop_models.dart';

typedef TrayIcon = ({Uint8List rgba, int width, int height});

final desktopWindowProvider = Provider<DesktopWindow>(
  (ref) => ChannelDesktopWindow(),
);

final trayPlatformProvider = Provider<TrayPlatform>(
  (ref) => RustTrayPlatform(),
);

final trayIconLoaderProvider = Provider<Future<TrayIcon> Function()>(
  (ref) => _loadTrayIcon,
);

final desktopShellEnabledProvider = Provider<bool>(
  (ref) =>
      Platform.isLinux && !Platform.environment.containsKey('FLUTTER_TEST'),
);

final sandboxedProvider = Provider<bool>(
  (ref) => (Platform.environment['FLATPAK_ID'] ?? '').isNotEmpty,
);

Future<TrayIcon> _loadTrayIcon() async {
  final data = await rootBundle.load('assets/branding/app_icon.png');
  final codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(),
    targetWidth: 64,
    targetHeight: 64,
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final icon = (
    rgba: bytes!.buffer.asUint8List(),
    width: image.width,
    height: image.height,
  );
  image.dispose();
  return icon;
}

class DesktopShellState {
  const DesktopShellState({
    this.started = false,
    this.trayAvailable = false,
    this.trayError,
    this.closePrompt = 0,
  });

  final bool started;
  final bool trayAvailable;
  final String? trayError;
  final int closePrompt;

  DesktopShellState copyWith({
    bool? started,
    bool? trayAvailable,
    String? Function()? trayError,
    int? closePrompt,
  }) => DesktopShellState(
    started: started ?? this.started,
    trayAvailable: trayAvailable ?? this.trayAvailable,
    trayError: trayError != null ? trayError() : this.trayError,
    closePrompt: closePrompt ?? this.closePrompt,
  );
}

final desktopShellProvider = NotifierProvider<DesktopShell, DesktopShellState>(
  DesktopShell.new,
);

class DesktopShell extends Notifier<DesktopShellState> {
  StreamSubscription<TrayMessage>? _tray;
  StreamSubscription<void>? _close;
  TrayMenuState? _last;
  bool _quitting = false;

  DesktopWindow get _window => ref.read(desktopWindowProvider);
  TrayPlatform get _trayPlatform => ref.read(trayPlatformProvider);

  @override
  DesktopShellState build() {
    ref.onDispose(() {
      _tray?.cancel();
      _close?.cancel();
    });
    ref.listen(receiverControllerProvider, (_, next) => _push(next));
    return const DesktopShellState();
  }

  Future<void> start() async {
    if (state.started) return;
    state = state.copyWith(started: true);
    _close = _window.closeRequests.listen((_) => onCloseRequested());
    try {
      await _window.setInterceptClose(true);
    } on Object catch (_) {}
    try {
      final icon = await ref.read(trayIconLoaderProvider)();
      _tray = _trayPlatform
          .start(
            rgba: icon.rgba,
            width: icon.width,
            height: icon.height,
            sandboxed: ref.read(sandboxedProvider),
          )
          .listen(
            _onTray,
            onError: (Object e) => state = state.copyWith(
              trayAvailable: false,
              trayError: () => '$e',
            ),
          );
    } on Object catch (e) {
      state = state.copyWith(trayAvailable: false, trayError: () => '$e');
    }
  }

  void _push(ReceiverState receiver) {
    if (!state.trayAvailable) return;
    final menu = trayMenuFor(receiver);
    if (menu == _last) return;
    _last = menu;
    unawaited(_trayPlatform.update(menu).catchError((Object _) {}));
  }

  void _onTray(TrayMessage message) {
    final receiver = ref.read(receiverControllerProvider.notifier);
    switch (message.command) {
      case TrayCommand.ready:
        state = state.copyWith(trayAvailable: true, trayError: () => null);
        _last = null;
        _push(ref.read(receiverControllerProvider));
      case TrayCommand.unavailable:
        state = state.copyWith(
          trayAvailable: false,
          trayError: () => message.text,
        );
      case TrayCommand.showWindow:
        unawaited(_window.show().catchError((Object _) {}));
      case TrayCommand.toggleStream:
        if (ref.read(receiverControllerProvider).phoneStreaming) {
          unawaited(receiver.stopPhoneStream());
        } else {
          unawaited(receiver.startPhoneStream());
        }
      case TrayCommand.switchCamera:
        unawaited(receiver.switchPhoneCamera());
      case TrayCommand.disconnect:
        unawaited(receiver.disconnect());
      case TrayCommand.quit:
        unawaited(quit());
    }
  }

  Future<void> onCloseRequested() async {
    if (state.trayAvailable) {
      await _window.hide();
      return;
    }
    if (ref.read(receiverControllerProvider).isBusy) {
      state = state.copyWith(closePrompt: state.closePrompt + 1);
      return;
    }
    await quit();
  }

  Future<void> keepRunningHidden() => _window.hide();

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    final receiver = ref.read(receiverControllerProvider.notifier);
    if (ref.read(receiverControllerProvider).isBusy) {
      await receiver.disconnect();
      for (
        var i = 0;
        i < 40 && ref.read(receiverControllerProvider).isBusy;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    try {
      await _trayPlatform.stop();
    } on Object catch (_) {}
    await _window.quit();
  }

  @visibleForTesting
  void handleTray(TrayMessage message) => _onTray(message);
}
