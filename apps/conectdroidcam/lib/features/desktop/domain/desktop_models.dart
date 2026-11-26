import '../../receiver/application/receiver_controller.dart';

enum TrayCommand {
  ready,
  unavailable,
  showWindow,
  toggleStream,
  switchCamera,
  disconnect,
  quit,
}

class TrayMessage {
  const TrayMessage(this.command, [this.text = '']);

  final TrayCommand command;
  final String text;
}

class TrayMenuState {
  const TrayMenuState({
    required this.statusLine,
    required this.tooltip,
    required this.connected,
    required this.streaming,
    required this.canStream,
    required this.canSwitch,
  });

  final String statusLine;
  final String tooltip;
  final bool connected;
  final bool streaming;
  final bool canStream;
  final bool canSwitch;

  @override
  bool operator ==(Object other) =>
      other is TrayMenuState &&
      other.statusLine == statusLine &&
      other.tooltip == tooltip &&
      other.connected == connected &&
      other.streaming == streaming &&
      other.canStream == canStream &&
      other.canSwitch == canSwitch;

  @override
  int get hashCode => Object.hash(
    statusLine,
    tooltip,
    connected,
    streaming,
    canStream,
    canSwitch,
  );
}

TrayMenuState trayMenuFor(ReceiverState s) {
  final name = s.phoneName ?? s.connectedTo ?? 'o celular';
  final statusLine = switch (s.phase) {
    ReceiverPhase.connected when s.phoneStreaming => 'Transmitindo de $name',
    ReceiverPhase.connected => 'Conectado a $name',
    ReceiverPhase.connecting => 'Conectando a $name…',
    ReceiverPhase.reconnecting => 'Reconectando a $name…',
    _ when s.phones.length == 1 => '1 celular encontrado na rede',
    _ when s.phones.length > 1 =>
      '${s.phones.length} celulares encontrados na rede',
    _ => 'Nenhum celular conectado',
  };
  final incoming = s.incoming;
  final tooltip = s.phoneStreaming && incoming != null
      ? '$statusLine · ${incoming.width}×${incoming.height} a ${incoming.fps} FPS'
      : statusLine;
  final caps = s.capabilities;
  return TrayMenuState(
    statusLine: statusLine,
    tooltip: tooltip,
    connected: s.isBusy,
    streaming: s.phoneStreaming,
    canStream: caps != null && (s.phoneStreaming || s.remoteMode != null),
    canSwitch: caps?.canSwitch ?? false,
  );
}
