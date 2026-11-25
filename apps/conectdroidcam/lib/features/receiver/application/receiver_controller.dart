import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/receiver_platform.dart';
import '../data/receiver_settings_store.dart';
import '../data/rust_receiver_platform.dart';
import '../domain/receiver_models.dart';

enum ReceiverPhase { starting, unavailable, idle, connecting, connected }

class PairingPrompt {
  const PairingPrompt({required this.code, required this.phoneFingerprint});

  final String code;
  final String phoneFingerprint;
}

class ReceiverState {
  const ReceiverState({
    this.phase = ReceiverPhase.starting,
    this.phones = const [],
    this.devices = const [],
    this.selectedDevice,
    this.format = ImageFormat.auto,
    this.outputSize = OutputSize.fullHd,
    this.ffmpegOk = true,
    this.autoConnect = true,
    this.trustedPhones = const {},
    this.fingerprints = const {},
    this.pairing,
    this.connectedTo,
    this.phoneName,
    this.phonePlatform,
    this.incoming,
    this.outgoing,
    this.stats,
    this.capabilities,
    this.remoteMode,
    this.remoteFps = 30,
    this.notice,
    this.error,
    this.discoveryError,
  });

  final ReceiverPhase phase;
  final List<Phone> phones;
  final List<VideoDevice> devices;

  final String? selectedDevice;

  final ImageFormat format;

  final OutputSize outputSize;
  final bool ffmpegOk;

  final bool autoConnect;

  final Set<String> trustedPhones;

  final Map<String, String> fingerprints;

  final PairingPrompt? pairing;

  final String? connectedTo;
  final String? phoneName;
  final String? phonePlatform;
  final IncomingVideo? incoming;
  final OutgoingVideo? outgoing;
  final LiveStats? stats;

  final PhoneCapabilities? capabilities;

  final PhoneMode? remoteMode;
  final int remoteFps;

  bool get phoneStreaming => capabilities?.streaming ?? false;

  final String? notice;

  final String? error;
  final String? discoveryError;

  bool get isBusy =>
      phase == ReceiverPhase.connecting || phase == ReceiverPhase.connected;

  bool get hasConectDroidCamDevice => devices.any((d) => d.isConectDroidCam);

  bool get hasDeviceFamily => devices.any((d) => d.shape != null);

  List<ShapeDevice> get shapeDevices => [for (final d in devices) ?d.shape];

  ReceiverState copyWith({
    ReceiverPhase? phase,
    List<Phone>? phones,
    List<VideoDevice>? devices,
    String? Function()? selectedDevice,
    ImageFormat? format,
    OutputSize? outputSize,
    bool? ffmpegOk,
    bool? autoConnect,
    Set<String>? trustedPhones,
    Map<String, String>? fingerprints,
    PairingPrompt? Function()? pairing,
    String? Function()? connectedTo,
    String? Function()? phoneName,
    String? Function()? phonePlatform,
    IncomingVideo? Function()? incoming,
    OutgoingVideo? Function()? outgoing,
    LiveStats? Function()? stats,
    PhoneCapabilities? Function()? capabilities,
    PhoneMode? Function()? remoteMode,
    int? remoteFps,
    String? Function()? notice,
    String? Function()? error,
    String? Function()? discoveryError,
  }) {
    return ReceiverState(
      phase: phase ?? this.phase,
      phones: phones ?? this.phones,
      devices: devices ?? this.devices,
      selectedDevice: selectedDevice != null
          ? selectedDevice()
          : this.selectedDevice,
      format: format ?? this.format,
      outputSize: outputSize ?? this.outputSize,
      ffmpegOk: ffmpegOk ?? this.ffmpegOk,
      autoConnect: autoConnect ?? this.autoConnect,
      trustedPhones: trustedPhones ?? this.trustedPhones,
      fingerprints: fingerprints ?? this.fingerprints,
      pairing: pairing != null ? pairing() : this.pairing,
      connectedTo: connectedTo != null ? connectedTo() : this.connectedTo,
      phoneName: phoneName != null ? phoneName() : this.phoneName,
      phonePlatform: phonePlatform != null
          ? phonePlatform()
          : this.phonePlatform,
      incoming: incoming != null ? incoming() : this.incoming,
      outgoing: outgoing != null ? outgoing() : this.outgoing,
      stats: stats != null ? stats() : this.stats,
      capabilities: capabilities != null ? capabilities() : this.capabilities,
      remoteMode: remoteMode != null ? remoteMode() : this.remoteMode,
      remoteFps: remoteFps ?? this.remoteFps,
      notice: notice != null ? notice() : this.notice,
      error: error != null ? error() : this.error,
      discoveryError: discoveryError != null
          ? discoveryError()
          : this.discoveryError,
    );
  }
}

final receiverPlatformProvider = Provider<ReceiverPlatform>(
  (ref) => RustReceiverPlatform(),
);

final receiverSettingsStoreProvider = Provider<ReceiverSettingsStore>(
  (ref) => FileReceiverSettingsStore(),
);

final previewFrameProvider = NotifierProvider<PreviewFrame, Uint8List?>(
  PreviewFrame.new,
);

class PreviewFrame extends Notifier<Uint8List?> {
  @override
  Uint8List? build() => null;

  void update(Uint8List? frame) => state = frame;
}

final receiverControllerProvider =
    NotifierProvider<ReceiverController, ReceiverState>(ReceiverController.new);

class ReceiverController extends Notifier<ReceiverState> {
  static const automaticDevice = 'auto';

  late ReceiverPlatform _platform;
  late ReceiverSettingsStore _store;
  StreamSubscription<PhoneChange>? _discovery;
  StreamSubscription<ReceiverUpdate>? _session;
  Timer? _rediscover;

  String? _connectedId;

  final Set<String> _noAuto = {};

  @override
  ReceiverState build() {
    final platform = _platform = ref.read(receiverPlatformProvider);
    _store = ref.read(receiverSettingsStoreProvider);
    final preview = ref.read(previewFrameProvider.notifier);
    ref.onDispose(() {
      _rediscover?.cancel();
      _discovery?.cancel();
      _session?.cancel();
      unawaited(platform.disconnect().catchError((Object _) {}));
      unawaited(platform.stopDiscovery().catchError((Object _) {}));
      try {
        preview.update(null);
      } on Object catch (_) {}
    });
    return const ReceiverState();
  }

  Future<void> start() async {
    if (state.phase != ReceiverPhase.starting &&
        state.phase != ReceiverPhase.unavailable) {
      return;
    }
    state = state.copyWith(phase: ReceiverPhase.starting, error: () => null);
    try {
      await _platform.init();
    } on Object catch (e) {
      state = state.copyWith(
        phase: ReceiverPhase.unavailable,
        error: () =>
            'Não consegui carregar o núcleo do app (libcdc_ffi.so): $e',
      );
      return;
    }
    final settings = await _store.load();
    final ffmpegOk = await _platform.ffmpegAvailable();
    state = state.copyWith(
      phase: ReceiverPhase.idle,
      ffmpegOk: ffmpegOk,
      autoConnect: settings.autoConnect,
      trustedPhones: settings.trustedPhones,
      fingerprints: settings.fingerprints,
      format: settings.format,
      outputSize: settings.outputSize,
    );
    await refreshDevices();
    _startDiscovery();
  }

  Future<void> refreshDevices() async {
    final devices = await _platform.listVideoDevices();
    final family = devices.any((d) => d.shape != null);
    final current = state.selectedDevice;
    final stillValid = current == automaticDevice
        ? family
        : current != null && devices.any((d) => d.path == current);
    String? choice = current;
    if (!stillValid) {
      choice = family
          ? automaticDevice
          : devices
                .where((d) => d.isConectDroidCam)
                .map((d) => d.path)
                .firstOrNull;
    }
    state = state.copyWith(devices: devices, selectedDevice: () => choice);
  }

  static const rediscoverEvery = Duration(seconds: 8);

  void _startDiscovery() {
    _rediscover?.cancel();
    _rediscover = Timer.periodic(rediscoverEvery, (_) {
      if (state.phase == ReceiverPhase.idle && state.phones.isEmpty) {
        _restartDiscovery();
      }
    });
    _subscribeDiscovery();
  }

  Future<void> rediscover() async {
    state = state.copyWith(phones: const []);
    await _restartDiscovery();
  }

  Future<void> _restartDiscovery() async {
    await _discovery?.cancel();
    try {
      await _platform.stopDiscovery();
    } on Object catch (_) {}
    _subscribeDiscovery();
  }

  void _subscribeDiscovery() {
    _discovery?.cancel();
    _discovery = _platform.discover().listen(
      (change) {
        final phones = [...state.phones];
        final lost = change.lostId;
        Phone? appeared;
        if (lost != null) {
          phones.removeWhere((p) => p.id == lost);
          _noAuto.remove(lost);
        } else if (change.phone case final phone?) {
          final i = phones.indexWhere((p) => p.id == phone.id);
          i >= 0 ? phones[i] = phone : phones.add(phone);
          appeared = phone;
        }
        state = state.copyWith(phones: phones, discoveryError: () => null);
        if (appeared != null) _maybeAutoConnect(appeared);
      },
      onError: (Object e) {
        state = state.copyWith(
          discoveryError: () =>
              'Não consegui procurar celulares na rede: $e. '
              'Conecte digitando o endereço.',
        );
      },
    );
  }

  void _maybeAutoConnect(Phone phone) {
    if (!state.autoConnect ||
        state.phase != ReceiverPhase.idle ||
        !state.trustedPhones.contains(phone.id) ||
        _noAuto.contains(phone.id)) {
      return;
    }
    connect(phone.address, name: phone.name, id: phone.id);
  }

  void selectDevice(String? path) {
    if (state.isBusy) return;
    state = state.copyWith(selectedDevice: () => path);
  }

  Future<void> setFormat(ImageFormat value) async {
    if (value == state.format) return;
    state = state.copyWith(format: value);
    await _saveSettings();
    if (state.isBusy) await _reconnect();
  }

  Future<void> setOutputSize(OutputSize value) async {
    if (value == state.outputSize) return;
    state = state.copyWith(outputSize: value);
    await _saveSettings();
    if (state.isBusy) await _reconnect();
  }

  Future<void> _reconnect() async {
    final address = state.connectedTo;
    if (address == null) return;
    final name = state.phoneName;
    final id = _connectedId;
    await _platform.disconnect();
    for (var i = 0; i < 100 && state.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (id != null) _noAuto.remove(id);
    await connect(address, name: name, id: id);
  }

  Future<void> setAutoConnect(bool value) async {
    state = state.copyWith(autoConnect: value);
    await _saveSettings();
    if (value) {
      for (final phone in state.phones) {
        _maybeAutoConnect(phone);
      }
    }
  }

  Future<void> forgetPhones() async {
    state = state.copyWith(trustedPhones: const {}, fingerprints: const {});
    await _saveSettings();
  }

  Future<void> _saveSettings() => _store.save(
    ReceiverSettings(
      autoConnect: state.autoConnect,
      trustedPhones: state.trustedPhones,
      fingerprints: state.fingerprints,
      format: state.format,
      outputSize: state.outputSize,
    ),
  );

  Future<void> connect(String address, {String? name, String? id}) async {
    final target = address.trim();
    if (state.isBusy || target.isEmpty) return;
    if (!_looksLikeAddress(target)) {
      state = state.copyWith(
        error: () => 'Endereço inválido. Use o formato 192.168.0.7:47821.',
      );
      return;
    }
    if (state.selectedDevice != null && !state.ffmpegOk) {
      state = state.copyWith(
        error: () =>
            'O ffmpeg não está instalado. Ele é necessário para escrever na webcam virtual.',
      );
      return;
    }
    _connectedId =
        id ??
        state.phones
            .where((p) => p.address == target)
            .map((p) => p.id)
            .firstOrNull;
    state = state.copyWith(
      phase: ReceiverPhase.connecting,
      connectedTo: () => target,
      phoneName: () => name,
      phonePlatform: () => null,
      incoming: () => null,
      outgoing: () => null,
      stats: () => null,
      capabilities: () => null,
      notice: () => null,
      error: () => null,
    );
    await _session?.cancel();
    _session = _platform
        .connect(
          address: target,
          videoDevice: state.selectedDevice == automaticDevice
              ? null
              : state.selectedDevice,
          shapeDevices: state.selectedDevice == automaticDevice
              ? state.shapeDevices
              : const [],
          format: state.format,
          size: state.outputSize,
          pinnedFingerprint: state.fingerprints[_phoneKey(target)],
        )
        .listen(
          _onUpdate,
          onError: (Object e) => _finish(error: '$e'),
          onDone: () {
            if (state.isBusy) {
              _finish(error: 'A conexão terminou de forma inesperada.');
            }
          },
        );
  }

  String _phoneKey(String address) => _connectedId ?? 'addr:$address';

  bool _looksLikeAddress(String text) {
    final i = text.lastIndexOf(':');
    if (i <= 0 || i == text.length - 1) return false;
    final port = int.tryParse(text.substring(i + 1));
    return port != null && port > 0 && port < 65536;
  }

  Future<void> disconnect() async {
    if (!state.isBusy) return;
    if (_connectedId case final id?) _noAuto.add(id);
    await _platform.disconnect();
  }

  void _onUpdate(ReceiverUpdate update) {
    switch (update) {
      case HelloUpdate(:final deviceName, :final platform):
        state = state.copyWith(
          phase: ReceiverPhase.connected,
          phoneName: () => deviceName,
          phonePlatform: () => platform,
        );
      case PairingCodeUpdate(:final code, :final phoneFingerprint):
        state = state.copyWith(
          pairing: () =>
              PairingPrompt(code: code, phoneFingerprint: phoneFingerprint),
        );
      case PairedUpdate(:final phoneFingerprint):
        _rememberPairedPhone(phoneFingerprint);
      case PairingDeniedUpdate(:final reason):
        if (_connectedId case final id?) _noAuto.add(id);
        state = state.copyWith(
          pairing: () => null,
          error: () => 'Pareamento não concluído: $reason',
        );
      case CapabilitiesUpdate(:final capabilities):
        _onCapabilities(capabilities);
      case ProfileUpdate(:final video):
        final active = state.capabilities?.find(video.width, video.height);
        state = state.copyWith(
          phase: ReceiverPhase.connected,
          incoming: () => video,
          remoteMode: active != null && state.phoneStreaming
              ? () => active
              : null,
          remoteFps: state.phoneStreaming && video.fps > 0 ? video.fps : null,
        );
      case OutputUpdate(:final video):
        state = state.copyWith(outgoing: () => video);
      case StatsUpdate(:final stats):
        state = state.copyWith(stats: () => stats);
      case PreviewUpdate(:final jpeg):
        ref.read(previewFrameProvider.notifier).update(jpeg);
      case SenderErrorUpdate(:final message):
        state = state.copyWith(error: () => 'O celular avisou: $message');
      case NoticeUpdate(:final message):
        state = state.copyWith(notice: () => message);
      case EndedUpdate():
        if (_connectedId case final id?) _noAuto.add(id);
        _finish();
      case FailedUpdate(:final message):
        if (_connectedId case final id?) _noAuto.add(id);
        _finish(error: message);
    }
  }

  void _onCapabilities(PhoneCapabilities caps) {
    var mode = state.remoteMode;
    if (mode == null || caps.find(mode.width, mode.height)?.available != true) {
      mode = caps.find(1920, 1080)?.available == true
          ? caps.find(1920, 1080)
          : caps.availableModes.firstOrNull;
    }
    var fps = state.remoteFps;
    if (caps.fpsOptions.isNotEmpty && !caps.fpsOptions.contains(fps)) {
      fps = caps.fpsOptions.contains(30) ? 30 : caps.fpsOptions.last;
    }
    state = state.copyWith(
      phase: ReceiverPhase.connected,
      capabilities: () => caps,
      remoteMode: () => mode,
      remoteFps: fps,
      incoming: caps.streaming ? null : () => null,
      outgoing: caps.streaming ? null : () => null,
      stats: caps.streaming ? null : () => null,
    );
    if (!caps.streaming) {
      try {
        ref.read(previewFrameProvider.notifier).update(null);
      } on Object catch (_) {}
    }
  }

  Future<void> _command(Future<String?> Function() send) async {
    final reason = await send();
    if (reason != null) {
      state = state.copyWith(
        error: () => 'Não consegui falar com o celular: $reason',
      );
    }
  }

  Future<void> selectRemoteMode(PhoneMode mode) async {
    final caps = state.capabilities;
    if (caps == null || !mode.available || mode == state.remoteMode) return;
    state = state.copyWith(remoteMode: () => mode, error: () => null);
    if (caps.streaming) {
      await _command(_platform.stopStream);
      await _command(
        () => _platform.startStream(mode.width, mode.height, _fpsFor(mode)),
      );
    }
  }

  int _fpsFor(PhoneMode mode) {
    final fps = state.remoteFps;
    return fps > mode.maxFps ? mode.maxFps : fps;
  }

  Future<void> selectRemoteFps(int fps) async {
    final caps = state.capabilities;
    if (caps == null || fps == state.remoteFps) return;
    state = state.copyWith(remoteFps: fps, error: () => null);
    if (caps.streaming) await _command(() => _platform.setFps(fps));
  }

  Future<void> startPhoneStream() async {
    final mode = state.remoteMode;
    if (mode == null || state.phoneStreaming) return;
    state = state.copyWith(error: () => null);
    await _command(
      () => _platform.startStream(mode.width, mode.height, _fpsFor(mode)),
    );
  }

  Future<void> stopPhoneStream() async {
    if (!state.phoneStreaming) return;
    await _command(_platform.stopStream);
  }

  Future<void> switchPhoneCamera() async {
    final caps = state.capabilities;
    if (caps == null || !caps.canSwitch) return;
    state = state.copyWith(error: () => null);
    await _command(() => _platform.switchCamera(front: !caps.front));
  }

  void _rememberPairedPhone(String fingerprint) {
    final key = _phoneKey(state.connectedTo ?? '');
    state = state.copyWith(
      pairing: () => null,
      trustedPhones: {...state.trustedPhones, key},
      fingerprints: {...state.fingerprints, key: fingerprint},
    );
    unawaited(_saveSettings());
  }

  Future<void> confirmPairing(bool accept) async {
    if (state.pairing == null) return;
    final reason = await _platform.confirmPairing(accept);
    if (!accept) {
      state = state.copyWith(pairing: () => null);
      await disconnect();
    } else if (reason != null) {
      state = state.copyWith(error: () => 'Não consegui confirmar: $reason');
    }
  }

  Future<void> unpair(String key) async {
    state = state.copyWith(
      trustedPhones: {...state.trustedPhones}..remove(key),
      fingerprints: {...state.fingerprints}..remove(key),
    );
    await _saveSettings();
  }

  void _finish({String? error}) {
    _connectedId = null;
    try {
      ref.read(previewFrameProvider.notifier).update(null);
    } on Object catch (_) {}
    state = state.copyWith(
      phase: ReceiverPhase.idle,
      connectedTo: () => null,
      phoneName: () => null,
      phonePlatform: () => null,
      incoming: () => null,
      outgoing: () => null,
      stats: () => null,
      capabilities: () => null,
      pairing: () => null,
      error: error != null ? () => error : null,
    );
  }
}
