import 'dart:typed_data';

import '../../../src/rust/api.dart' as api;
import '../domain/desktop_models.dart';

abstract interface class TrayPlatform {
  Stream<TrayMessage> start({
    required Uint8List rgba,
    required int width,
    required int height,
    required bool sandboxed,
  });
  Future<void> update(TrayMenuState state);
  Future<void> stop();
}

class RustTrayPlatform implements TrayPlatform {
  @override
  Stream<TrayMessage> start({
    required Uint8List rgba,
    required int width,
    required int height,
    required bool sandboxed,
  }) => api
      .trayStart(
        iconRgba: rgba,
        width: width,
        height: height,
        sandboxed: sandboxed,
      )
      .map(
        (e) => TrayMessage(switch (e.action) {
          api.TrayAction.ready => TrayCommand.ready,
          api.TrayAction.unavailable => TrayCommand.unavailable,
          api.TrayAction.showWindow => TrayCommand.showWindow,
          api.TrayAction.toggleStream => TrayCommand.toggleStream,
          api.TrayAction.switchCamera => TrayCommand.switchCamera,
          api.TrayAction.disconnect => TrayCommand.disconnect,
          api.TrayAction.quit => TrayCommand.quit,
        }, e.text),
      );

  @override
  Future<void> update(TrayMenuState state) => api.trayUpdate(
    status: api.TrayStatus(
      tooltip: state.tooltip,
      statusLine: state.statusLine,
      connected: state.connected,
      streaming: state.streaming,
      canStream: state.canStream,
      canSwitch: state.canSwitch,
    ),
  );

  @override
  Future<void> stop() => api.trayStop();
}
