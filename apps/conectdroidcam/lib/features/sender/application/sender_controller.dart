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
    this.profiles = const [],
    this.selected = VideoProfile.hd,
    this.addresses = const [],
    this.stream,
    this.clientPeer,
    this.fps = 0,
    this.bitrateKbps = 0,
    this.dropped = 0,
    this.error,
    this.busy = false,
  });

  final SenderPhase phase;
  final PreviewInfo? preview;
  final List<ProfileAvailability> profiles;
  final VideoProfile selected;
  final List<LocalAddress> addresses;
  final StreamInfo? stream;

  /// Endereço do computador conectado, ou `null` se ninguém está conectado.
  final String? clientPeer;
  final double fps;
  final double bitrateKbps;
  final int dropped;
  final String? error;

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

  SenderState copyWith({
    SenderPhase? phase,
    PreviewInfo? Function()? preview,
    List<ProfileAvailability>? profiles,
    VideoProfile? selected,
    List<LocalAddress>? addresses,
    StreamInfo? Function()? stream,
    String? Function()? clientPeer,
    double? fps,
    double? bitrateKbps,
    int? dropped,
    String? Function()? error,
    bool? busy,
  }) {
    return SenderState(
      phase: phase ?? this.phase,
      preview: preview != null ? preview() : this.preview,
      profiles: profiles ?? this.profiles,
      selected: selected ?? this.selected,
      addresses: addresses ?? this.addresses,
      stream: stream != null ? stream() : this.stream,
      clientPeer: clientPeer != null ? clientPeer() : this.clientPeer,
      fps: fps ?? this.fps,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      dropped: dropped ?? this.dropped,
      error: error != null ? error() : this.error,
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
      final profiles = await _platform.listProfiles();
      final addresses = await _platform.localAddresses();
      _listen();

      // Mantém a escolha atual se ainda valer; senão, o primeiro perfil disponível.
      final usable = profiles.where((p) => p.available).map((p) => p.profile);
      final selected = usable.contains(state.selected)
          ? state.selected
          : (usable.isEmpty ? state.selected : usable.first);
      state = state.copyWith(
        phase: SenderPhase.ready,
        preview: () => preview,
        profiles: profiles,
        addresses: addresses,
        selected: selected,
        busy: false,
      );
    } on SenderException catch (e) {
      _fail(e.message);
    }
  }

  void select(VideoProfile profile) {
    if (state.isStreaming || state.busy) return;
    final entry = state.profiles.where((p) => p.profile == profile);
    if (entry.isEmpty || !entry.first.available) return;
    state = state.copyWith(selected: profile);
  }

  Future<void> startStreaming() async {
    if (state.busy || state.phase != SenderPhase.ready) return;
    state = state.copyWith(busy: true, error: () => null);
    try {
      final stream = await _platform.startStreaming(state.selected);
      final addresses = await _platform.localAddresses();
      state = state.copyWith(
        phase: SenderPhase.streaming,
        stream: () => stream,
        addresses: addresses,
        clientPeer: () => null,
        fps: 0,
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
      clientPeer: () => null,
      fps: 0,
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
          fps: fps,
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
      case ErrorEvent(:final message):
        // O código nativo já parou tudo; a interface só reflete o estado.
        _fail(message);
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
