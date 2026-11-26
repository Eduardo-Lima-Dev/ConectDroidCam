import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sender_platform.dart';
import '../domain/sender_models.dart';

enum SenderPhase {
  initial,

  needsPermission,

  permissionDenied,

  starting,

  ready,

  streaming,

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
    this.clientName,
    this.measuredFps = 0,
    this.bitrateKbps = 0,
    this.dropped = 0,
    this.error,
    this.notice,
    this.success,
    this.visibleAs,
    this.visibilityError,
    this.busy = false,
    this.pairing,
    this.pairedComputers = const [],
  });

  final SenderPhase phase;
  final PreviewInfo? preview;
  final SenderCapabilities capabilities;
  final VideoMode selected;

  final int selectedFps;
  final List<LocalAddress> addresses;
  final StreamInfo? stream;

  final String? clientPeer;

  final String? clientName;

  final double measuredFps;
  final double bitrateKbps;
  final int dropped;

  final String? error;

  final String? notice;

  final String? success;

  final String? visibleAs;

  final String? visibilityError;

  final bool busy;

  final PairingRequestEvent? pairing;

  final List<PairedComputer> pairedComputers;

  bool get isStreaming => phase == SenderPhase.streaming;

  LocalAddress? get lanAddress {
    for (final address in addresses) {
      if (address.isLan) return address;
    }
    return addresses.isEmpty ? null : addresses.first;
  }

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
    String? Function()? clientName,
    double? measuredFps,
    double? bitrateKbps,
    int? dropped,
    String? Function()? error,
    String? Function()? notice,
    String? Function()? success,
    String? Function()? visibleAs,
    String? Function()? visibilityError,
    bool? busy,
    PairingRequestEvent? Function()? pairing,
    List<PairedComputer>? pairedComputers,
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
      clientName: clientName != null ? clientName() : this.clientName,
      measuredFps: measuredFps ?? this.measuredFps,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      dropped: dropped ?? this.dropped,
      error: error != null ? error() : this.error,
      notice: notice != null ? notice() : this.notice,
      success: success != null ? success() : this.success,
      visibleAs: visibleAs != null ? visibleAs() : this.visibleAs,
      visibilityError: visibilityError != null
          ? visibilityError()
          : this.visibilityError,
      busy: busy ?? this.busy,
      pairing: pairing != null ? pairing() : this.pairing,
      pairedComputers: pairedComputers ?? this.pairedComputers,
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
  bool _restartOnReturn = false;

  @override
  SenderState build() {
    final platform = _platform = ref.read(senderPlatformProvider);
    ref.onDispose(() {
      _events?.cancel();
      unawaited(platform.stopPreview().catchError((Object _) {}));
    });
    return const SenderState();
  }

  Future<void> start() async {
    if (state.busy || state.phase == SenderPhase.starting) return;
    _restartOnReturn = false;
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
      final paired = await _platform.listPaired();
      _listen();

      final selected = _pickMode(capabilities, state.selected);
      state = state.copyWith(
        phase: SenderPhase.ready,
        preview: () => preview,
        capabilities: capabilities,
        addresses: addresses,
        pairedComputers: paired,
        selected: selected,
        selectedFps: capabilities.clampFps(selected, state.selectedFps),
        busy: false,
      );
    } on SenderException catch (e) {
      _fail(e.message);
    }
  }

  Future<void> openAppSettings() async {
    try {
      await _platform.openAppSettings();
    } on SenderException catch (_) {}
  }

  Future<void> onResumed() async {
    if (state.phase == SenderPhase.failed && _restartOnReturn) {
      _restartOnReturn = false;
      await start();
      return;
    }
    if (state.phase != SenderPhase.permissionDenied) return;
    try {
      if (await _platform.hasCameraPermission()) await start();
    } on SenderException catch (_) {}
  }

  Future<void> confirmPairing(bool accept) async {
    if (state.pairing == null) return;
    state = state.copyWith(pairing: () => null);
    try {
      await _platform.confirmPairing(accept);
    } on SenderException catch (e) {
      state = state.copyWith(notice: () => e.message);
    }
  }

  void clearSuccess() {
    if (state.success != null) state = state.copyWith(success: () => null);
  }

  Future<void> unpair(String fingerprint) async {
    try {
      await _platform.unpair(fingerprint);
      state = state.copyWith(pairedComputers: await _platform.listPaired());
    } on SenderException catch (e) {
      state = state.copyWith(notice: () => e.message);
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
      state = state.copyWith(busy: false, notice: () => e.message);
    }
  }

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
      case ClientEvent(:final connected, :final peer, :final name):
        state = state.copyWith(
          clientPeer: () => connected ? peer : null,
          clientName: () => connected ? name : null,
        );
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
      case PairingRequestEvent():
        state = state.copyWith(pairing: () => event);
      case PairingEndedEvent(:final paired, :final computer, :final reason):
        state = paired
            ? state.copyWith(
                pairing: () => null,
                notice: () => null,
                success: () => '$computer foi pareado.',
              )
            : state.copyWith(
                pairing: () => null,
                notice: () =>
                    'Pareamento com $computer não concluído'
                    '${reason != null ? ': $reason' : ''}.',
              );
        if (paired) unawaited(_reloadPaired());
      case DiscoveryEvent(:final registered, :final name, :final error):
        state = state.copyWith(
          visibleAs: () => registered ? name : null,
          visibilityError: () => registered ? null : error,
        );
      case ErrorEvent(:final message, :final recoverable):
        _fail(message);
        _restartOnReturn = recoverable;
    }
  }

  Future<void> _reloadPaired() async {
    try {
      state = state.copyWith(pairedComputers: await _platform.listPaired());
    } on SenderException catch (_) {}
  }

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
      clientName: () => null,
      error: () => message,
      busy: false,
    );
  }
}
