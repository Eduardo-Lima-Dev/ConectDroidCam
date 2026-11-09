import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sender_platform.dart';
import '../domain/sender_models.dart';

/// Em que ponto do fluxo o emissor está.
enum SenderPhase {
  /// Ainda não perguntamos nada ao sistema.
  initial,

  /// Falta a permissão de câmera.
  needsPermission,

  /// O usuário negou. Só dá para continuar pelas configurações do sistema.
  permissionDenied,

  /// Abrindo a câmera.
  starting,

  /// Prévia ativa, sem transmitir.
  ready,

  /// Transmissão ligada (com ou sem cliente conectado).
  streaming,

  /// Falha; veja [SenderState.error].
  failed,
}

class SenderState {
  const SenderState({
    this.phase = SenderPhase.initial,
    this.preview,
    this.capabilities = SenderCapabilities.empty,
    this.selected = VideoMode.hd,
    this.selectedFps = 30,
    this.addresses = const [],
    this.stream,
    this.clientPeer,
    this.measuredFps = 0,
    this.bitrateKbps = 0,
    this.dropped = 0,
    this.error,
    this.notice,
    this.visibleAs,
    this.visibilityError,
    this.busy = false,
  });

  final SenderPhase phase;
  final PreviewInfo? preview;
  final SenderCapabilities capabilities;
  final VideoMode selected;

  /// FPS escolhido pelo usuário. Pode ser mudado com a transmissão ligada.
  final int selectedFps;
  final List<LocalAddress> addresses;
  final StreamInfo? stream;

  /// Endereço do computador conectado, ou `null` se ninguém está conectado.
  final String? clientPeer;

  /// FPS medido no envio, que pode diferir do escolhido.
  final double measuredFps;
  final double bitrateKbps;
  final int dropped;

  /// Falha que interrompeu o emissor.
  final String? error;

  /// Aviso que não interrompe nada, como um FPS que o aparelho recusou.
  final String? notice;

  /// Nome com que o celular aparece na rede para o computador, quando já foi anunciado.
  final String? visibleAs;

  /// Por que o anúncio na rede falhou. O computador ainda conecta pelo endereço.
  final String? visibilityError;

  /// Uma operação assíncrona está em andamento; os botões ficam desativados.
  final bool busy;

  bool get isStreaming => phase == SenderPhase.streaming;

  /// Primeiro endereço de rede local, para mostrar ao usuário.
  LocalAddress? get lanAddress {
    for (final address in addresses) {
      if (address.isLan) return address;
    }
    return addresses.isEmpty ? null : addresses.first;
  }

  /// Dá para iniciar a transmissão com a resolução escolhida?
  bool get canStart => capabilities.find(selected)?.available ?? false;

  SenderState copyWith({
    SenderPhase? phase,
    PreviewInfo? Function()? preview,
    SenderCapabilities? capabilities,
    VideoMode? selected,
    int? selectedFps,
    List<LocalAddress>? addresses,
    StreamInfo? Function()? stream,
    String? Function()? clientPeer,
    double? measuredFps,
    double? bitrateKbps,
    int? dropped,
    String? Function()? error,
    String? Function()? notice,
    String? Function()? visibleAs,
    String? Function()? visibilityError,
    bool? busy,
  }) {
    return SenderState(
      phase: phase ?? this.phase,
      preview: preview != null ? preview() : this.preview,
      capabilities: capabilities ?? this.capabilities,
      selected: selected ?? this.selected,
      selectedFps: selectedFps ?? this.selectedFps,
      addresses: addresses ?? this.addresses,
      stream: stream != null ? stream() : this.stream,
      clientPeer: clientPeer != null ? clientPeer() : this.clientPeer,
      measuredFps: measuredFps ?? this.measuredFps,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      dropped: dropped ?? this.dropped,
      error: error != null ? error() : this.error,
      notice: notice != null ? notice() : this.notice,
      visibleAs: visibleAs != null ? visibleAs() : this.visibleAs,
      visibilityError: visibilityError != null
          ? visibilityError()
          : this.visibilityError,
      busy: busy ?? this.busy,
    );
  }
}

final senderPlatformProvider = Provider<SenderPlatform>(
  (ref) => ChannelSenderPlatform(),
);

final senderControllerProvider =
    NotifierProvider<SenderController, SenderState>(SenderController.new);

class SenderController extends Notifier<SenderState> {
  StreamSubscription<SenderEvent>? _events;

  late SenderPlatform _platform;

  @override
  SenderState build() {
    // Guardada aqui porque o Riverpod não deixa usar `ref` dentro de `onDispose`.
    final platform = _platform = ref.read(senderPlatformProvider);
    ref.onDispose(() {
      _events?.cancel();
      // Libera a câmera ao sair; ignora falhas porque o app está fechando.
      unawaited(platform.stopPreview().catchError((Object _) {}));
    });
    return const SenderState();
  }

  /// Pede a permissão (se preciso) e abre a prévia.
  Future<void> start() async {
    if (state.busy || state.phase == SenderPhase.starting) return;
    state = state.copyWith(
      phase: SenderPhase.starting,
      busy: true,
      error: () => null,
      notice: () => null,
    );
    try {
      var granted = await _platform.hasCameraPermission();
      if (!granted) {
        state = state.copyWith(phase: SenderPhase.needsPermission);
        granted = await _platform.requestCameraPermission();
      }
      if (!granted) {
        state = state.copyWith(
          phase: SenderPhase.permissionDenied,
          busy: false,
        );
        return;
      }

      final preview = await _platform.startPreview();
      final capabilities = await _platform.listModes();
      final addresses = await _platform.localAddresses();
      _listen();

      // Mantém a escolha atual se ainda valer; senão, a primeira principal disponível.
      final selected = _pickMode(capabilities, state.selected);
      state = state.copyWith(
        phase: SenderPhase.ready,
        preview: () => preview,
        capabilities: capabilities,
        addresses: addresses,
        selected: selected,
        selectedFps: capabilities.clampFps(selected, state.selectedFps),
        busy: false,
      );
    } on SenderException catch (e) {
      _fail(e.message);
    }
  }

  VideoMode _pickMode(SenderCapabilities capabilities, VideoMode preferred) {
    if (capabilities.find(preferred)?.available ?? false) return preferred;
    for (final item in capabilities.mainModes) {
      if (item.available) return item.mode;
    }
    for (final item in capabilities.modes) {
      if (item.available) return item.mode;
    }
    return preferred;
  }

  void select(VideoMode mode) {
    if (state.isStreaming || state.busy) return;
    if (!(state.capabilities.find(mode)?.available ?? false)) return;
    state = state.copyWith(
      selected: mode,
      selectedFps: state.capabilities.clampFps(mode, state.selectedFps),
      notice: () => null,
    );
  }

  /// Escolhe o FPS. Com a transmissão ligada, aplica na hora.
  Future<void> selectFps(int fps) async {
    if (state.busy || fps == state.selectedFps) return;
    if (!state.capabilities.fpsFor(state.selected).contains(fps)) return;

    if (!state.isStreaming) {
      state = state.copyWith(selectedFps: fps, notice: () => null);
      return;
    }
    state = state.copyWith(busy: true, notice: () => null);
    try {
      await _platform.setFps(fps);
      state = state.copyWith(selectedFps: fps, busy: false);
    } on SenderException catch (e) {
      // Falhar em trocar o FPS não derruba a transmissão.
      state = state.copyWith(busy: false, notice: () => e.message);
    }
  }

  /// Troca entre a câmera frontal e a traseira. Com a transmissão ligada ela continua: o
  /// vídeo só para por cerca de um segundo. Se a câmera nova não servir (por exemplo, não
  /// oferece a resolução em uso), a troca é recusada e nada muda.
  Future<void> switchCamera() async {
    final current = state.preview;
    if (state.busy || current == null || !current.canSwitch) return;
    if (state.phase != SenderPhase.ready && !state.isStreaming) return;
    state = state.copyWith(busy: true, notice: () => null);
    try {
      final preview = await _platform.switchCamera(front: !current.isFront);
      state = state.copyWith(preview: () => preview);
      await _refreshModes();
      state = state.copyWith(busy: false);
    } on SenderException catch (e) {
      state = state.copyWith(busy: false, notice: () => e.message);
    }
  }

  Future<void> startStreaming() async {
    if (state.busy || state.phase != SenderPhase.ready || !state.canStart) {
      return;
    }
    state = state.copyWith(busy: true, error: () => null, notice: () => null);
    try {
      final stream = await _platform.startStreaming(
        state.selected,
        state.selectedFps,
      );
      final addresses = await _platform.localAddresses();
      state = state.copyWith(
        phase: SenderPhase.streaming,
        stream: () => stream,
        addresses: addresses,
        clientPeer: () => null,
        measuredFps: 0,
        bitrateKbps: 0,
        dropped: 0,
        busy: false,
      );
    } on SenderException catch (e) {
      _fail(e.message);
    }
  }

  Future<void> stopStreaming() async {
    if (state.busy || !state.isStreaming) return;
    state = state.copyWith(busy: true);
    try {
      await _platform.stopStreaming();
    } on SenderException catch (e) {
      _fail(e.message);
      return;
    }
    state = state.copyWith(
      phase: SenderPhase.ready,
      stream: () => null,
      measuredFps: 0,
      bitrateKbps: 0,
      busy: false,
    );
  }

  void _listen() {
    _events ??= _platform.events.listen(_onEvent);
  }

  void _onEvent(SenderEvent event) {
    switch (event) {
      case ClientEvent(:final connected, :final peer):
        state = state.copyWith(clientPeer: () => connected ? peer : null);
      case StatsEvent(:final fps, :final bitrateKbps, :final dropped):
        state = state.copyWith(
          measuredFps: fps,
          bitrateKbps: bitrateKbps,
          dropped: dropped,
        );
      case RotationEvent(:final displayRotation):
        final preview = state.preview;
        if (preview != null) {
          state = state.copyWith(
            preview: () => preview.copyWith(displayRotation: displayRotation),
          );
        }
      case RemoteStreamEvent(:final streaming, :final stream):
        // O computador mandou: o estado daqui acompanha.
        if (streaming && stream != null) {
          state = state.copyWith(
            phase: SenderPhase.streaming,
            stream: () => stream,
            selected: stream.mode,
            selectedFps: stream.fps,
            measuredFps: 0,
            bitrateKbps: 0,
            dropped: 0,
            busy: false,
            notice: () => null,
          );
        } else if (state.isStreaming) {
          state = state.copyWith(
            phase: SenderPhase.ready,
            stream: () => null,
            measuredFps: 0,
            bitrateKbps: 0,
            busy: false,
          );
        }
      case CameraChangedEvent(:final preview):
        state = state.copyWith(preview: () => preview);
        unawaited(_refreshModes());
      case DiscoveryEvent(:final registered, :final name, :final error):
        state = state.copyWith(
          visibleAs: () => registered ? name : null,
          visibilityError: () => registered ? null : error,
        );
      case ErrorEvent(:final message):
        // O código nativo já parou tudo; a interface só reflete o estado.
        _fail(message);
    }
  }

  /// Relê o que a câmera em uso oferece, depois de ela mudar.
  Future<void> _refreshModes() async {
    try {
      final capabilities = await _platform.listModes();
      final selected = state.isStreaming
          ? state.selected
          : _pickMode(capabilities, state.selected);
      state = state.copyWith(
        capabilities: capabilities,
        selected: selected,
        selectedFps: capabilities.clampFps(selected, state.selectedFps),
      );
    } on SenderException catch (e) {
      state = state.copyWith(notice: () => e.message);
    }
  }

  void _fail(String message) {
    state = state.copyWith(
      phase: SenderPhase.failed,
      preview: () => null,
      stream: () => null,
      clientPeer: () => null,
      error: () => message,
      busy: false,
    );
  }
}
