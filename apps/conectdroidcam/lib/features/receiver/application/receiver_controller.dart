import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/receiver_platform.dart';
import '../data/receiver_settings_store.dart';
import '../data/rust_receiver_platform.dart';
import '../domain/friendly_errors.dart';
import '../domain/receiver_models.dart';

enum ReceiverPhase {
  starting,
  unavailable,
  idle,
  connecting,
  connected,
  reconnecting,
}

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
    this.phoneNames = const {},
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
    this.reconnectAttempt = 0,
    this.notice,
    this.error,
    this.errorDetails,
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

  final Map<String, String> phoneNames;

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

  final int reconnectAttempt;

  final String? notice;

  final String? error;
  final String? errorDetails;
  final String? discoveryError;

  bool get isBusy =>
      phase == ReceiverPhase.connecting ||
      phase == ReceiverPhase.connected ||
      phase == ReceiverPhase.reconnecting;

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
    Map<String, String>? phoneNames,
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
    int? reconnectAttempt,
    String? Function()? notice,
    String? Function()? error,
    String? Function()? errorDetails,
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
      phoneNames: phoneNames ?? this.phoneNames,
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
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      notice: notice != null ? notice() : this.notice,
      error: error != null ? error() : this.error,
      errorDetails: errorDetails != null
          ? errorDetails()
          : error != null
          ? null
          : this.errorDetails,
      discoveryError: discoveryError != null
          ? discoveryError()
          : this.discoveryError,
    );
  }
}

final receiverPlatformProvider = Provider<ReceiverPlatform>(
  (ref) => RustReceiverPlatform(),
);

final reconnectDelaysProvider = Provider<List<Duration>>(
  (ref) => const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 5),
    Duration(seconds: 5),
    Duration(seconds: 5),
    Duration(seconds: 5),
  ],
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

  bool _userStopped = false;
  bool _established = false;
  bool _pairingFailed = false;
  int _run = 0;
  Completer<bool>? _attempt;
  bool _idleOn = false;
  bool _resumeStream = false;
  PhoneMode? _resumeMode;
  int _resumeFps = 30;

  @override
  ReceiverState build() {
    final platform = _platform = ref.read(receiverPlatformProvider);
    _store = ref.read(receiverSettingsStoreProvider);
    final preview = ref.read(previewFrameProvider.notifier);
    ref.onDispose(() {
      _rediscover?.cancel();
      _discovery?.cancel();
      _session?.cancel();
      _run++;
      unawaited(platform.disconnect().catchError((Object _) {}));
      unawaited(platform.stopIdleFeed().catchError((Object _) {}));
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
            'Uma parte interna do app não carregou. Reinstale o ConectDroidCam; '
            'se continuar, relate o problema com os detalhes abaixo.',
        errorDetails: () => 'libcdc_ffi.so: $e',
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
      phoneNames: settings.phoneNames,
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
    _userStopped = true;
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
    state = state.copyWith(
      trustedPhones: const {},
      fingerprints: const {},
      phoneNames: const {},
    );
    await _saveSettings();
  }

  Future<void> _saveSettings() => _store.save(
    ReceiverSettings(
      autoConnect: state.autoConnect,
      trustedPhones: state.trustedPhones,
      fingerprints: state.fingerprints,
      phoneNames: state.phoneNames,
      format: state.format,
      outputSize: state.outputSize,
    ),
  );

  void dismissError() {
    if (state.error != null) state = state.copyWith(error: () => null);
  }

  void dismissNotice() {
    if (state.notice != null) state = state.copyWith(notice: () => null);
  }

  Future<void> connect(String address, {String? name, String? id}) async {
    final typed = address.trim();
    if (state.isBusy || typed.isEmpty) return;
    final target = normalizeAddress(typed);
    if (target == null) {
      state = state.copyWith(
        error: () =>
            'Endereço inválido. Use o formato 192.168.0.7 ou 192.168.0.7:47821.',
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
    _run++;
    _userStopped = false;
    _established = false;
    _pairingFailed = false;
    _resumeStream = false;
    await _stopIdle();
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
    await _open(target);
  }

  Future<void> _open(String target) async {
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
          onError: (Object e) {
            if (_completeAttempt(false)) return;
            _finish(error: '$e');
          },
          onDone: () {
            if (_completeAttempt(false)) return;
            if (state.phase == ReceiverPhase.connecting ||
                state.phase == ReceiverPhase.connected) {
              _finish(error: 'A conexão terminou de forma inesperada.');
            }
          },
        );
  }

  bool _completeAttempt(bool ok) {
    final attempt = _attempt;
    if (attempt == null || attempt.isCompleted) return false;
    attempt.complete(ok);
    return true;
  }

  bool get _shouldReconnect =>
      !_userStopped &&
      _established &&
      !_pairingFailed &&
      state.connectedTo != null;

  Future<void> _beginReconnect() async {
    final target = state.connectedTo!;
    final run = ++_run;
    _resumeStream = state.phoneStreaming;
    _resumeMode = state.remoteMode;
    _resumeFps = state.remoteFps;
    _established = false;
    final out = state.outgoing;
    try {
      ref.read(previewFrameProvider.notifier).update(null);
    } on Object catch (_) {}
    state = state.copyWith(
      phase: ReceiverPhase.reconnecting,
      reconnectAttempt: 0,
      incoming: () => null,
      stats: () => null,
      capabilities: () => null,
      pairing: () => null,
      notice: () => null,
      error: () => null,
    );
    await _startIdle(out);
    final delays = ref.read(reconnectDelaysProvider);
    for (var i = 0; i < delays.length; i++) {
      await Future<void>.delayed(delays[i]);
      if (run != _run) return;
      state = state.copyWith(reconnectAttempt: i + 1);
      await _stopIdle();
      final attempt = _attempt = Completer<bool>();
      await _open(target);
      final ok = await attempt.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
      _attempt = null;
      if (run != _run) return;
      if (ok) return;
      await _session?.cancel();
      await _platform.disconnect();
      await _startIdle(out);
    }
    if (run != _run) return;
    await _stopIdle();
    if (_connectedId case final id?) _noAuto.add(id);
    _finish(
      error:
          'A conexão com o celular caiu e não voltou. Confira se o '
          'ConectDroidCam está aberto no celular e conecte de novo.',
    );
  }

  Future<void> _startIdle(OutgoingVideo? out) async {
    final device = out?.device;
    if (out == null || device == null || device.startsWith('null')) return;
    final error = await _platform.startIdleFeed(device, out.width, out.height);
    _idleOn = error == null;
  }

  Future<void> _stopIdle() async {
    if (!_idleOn) return;
    _idleOn = false;
    await _platform.stopIdleFeed();
  }

  String _phoneKey(String address) => _connectedId ?? 'addr:$address';

  Future<void> disconnect() async {
    if (!state.isBusy) return;
    if (_connectedId case final id?) _noAuto.add(id);
    _userStopped = true;
    if (state.phase == ReceiverPhase.reconnecting) {
      _run++;
      _completeAttempt(false);
      await _platform.disconnect();
      await _stopIdle();
      _finish();
      return;
    }
    await _platform.disconnect();
  }

  void _onUpdate(ReceiverUpdate update) {
    switch (update) {
      case HelloUpdate(:final deviceName, :final platform):
        _established = true;
        _completeAttempt(true);
        state = state.copyWith(
          phase: ReceiverPhase.connected,
          reconnectAttempt: 0,
          phoneName: () => deviceName,
          phonePlatform: () => platform,
        );
      case PairingCodeUpdate(:final code, :final phoneFingerprint):
        state = state.copyWith(
          pairing: () =>
              PairingPrompt(code: code, phoneFingerprint: phoneFingerprint),
        );
      case PhoneIdentityUpdate(:final phoneFingerprint):
        _recognizePhone(phoneFingerprint);
      case PairedUpdate(:final phoneFingerprint):
        _rememberPairedPhone(phoneFingerprint);
      case PairingDeniedUpdate(:final reason):
        _pairingFailed = true;
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
        if (_completeAttempt(false)) return;
        if (state.phase == ReceiverPhase.reconnecting) return;
        if (_shouldReconnect) {
          unawaited(_beginReconnect());
          return;
        }
        if (_connectedId case final id?) _noAuto.add(id);
        _finish();
      case FailedUpdate(:final message):
        if (_completeAttempt(false)) return;
        if (state.phase == ReceiverPhase.reconnecting) return;
        if (_shouldReconnect) {
          unawaited(_beginReconnect());
          return;
        }
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
    if (_resumeStream) {
      _resumeStream = false;
      final resume = _resumeMode;
      if (!caps.streaming &&
          resume != null &&
          caps.find(resume.width, resume.height)?.available == true) {
        state = state.copyWith(remoteMode: () => resume, remoteFps: _resumeFps);
        unawaited(startPhoneStream());
      }
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

  void _recognizePhone(String fingerprint) {
    final key = _phoneKey(state.connectedTo ?? '');
    if (state.fingerprints[key] == fingerprint) return;
    final matches = [
      for (final e in state.fingerprints.entries)
        if (e.value == fingerprint && e.key != key) e.key,
    ];
    if (matches.isEmpty) return;
    final name = matches.map((k) => state.phoneNames[k]).nonNulls.firstOrNull;
    final trusted = {...state.trustedPhones};
    final prints = {...state.fingerprints};
    final names = {...state.phoneNames};
    for (final k in matches.where((k) => k.startsWith('addr:'))) {
      trusted.remove(k);
      prints.remove(k);
      names.remove(k);
    }
    trusted.add(key);
    prints[key] = fingerprint;
    if (name != null) names[key] = name;
    state = state.copyWith(
      trustedPhones: trusted,
      fingerprints: prints,
      phoneNames: names,
    );
    unawaited(_saveSettings());
  }

  void _rememberPairedPhone(String fingerprint) {
    final key = _phoneKey(state.connectedTo ?? '');
    final name = state.phoneName;
    state = state.copyWith(
      pairing: () => null,
      trustedPhones: {...state.trustedPhones, key},
      fingerprints: {...state.fingerprints, key: fingerprint},
      phoneNames: {...state.phoneNames, key: ?name},
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
      phoneNames: {...state.phoneNames}..remove(key),
    );
    await _saveSettings();
  }

  void _finish({String? error}) {
    _connectedId = null;
    final friendly = error == null ? null : friendlyError(error);
    try {
      ref.read(previewFrameProvider.notifier).update(null);
    } on Object catch (_) {}
    state = state.copyWith(
      phase: ReceiverPhase.idle,
      reconnectAttempt: 0,
      connectedTo: () => null,
      phoneName: () => null,
      phonePlatform: () => null,
      incoming: () => null,
      outgoing: () => null,
      stats: () => null,
      capabilities: () => null,
      pairing: () => null,
      error: friendly != null ? () => friendly.message : null,
      errorDetails: friendly != null ? () => friendly.details : null,
    );
  }
}

const defaultPhonePort = 47821;

String? normalizeAddress(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  String host;
  String? port;
  if (t.startsWith('[')) {
    final end = t.indexOf(']');
    if (end < 0) return null;
    host = t.substring(1, end);
    final rest = t.substring(end + 1);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return null;
      port = rest.substring(1);
    }
    if (!_isIpv6(host)) return null;
    host = '[$host]';
  } else {
    final colons = ':'.allMatches(t).length;
    if (colons > 1) {
      if (!_isIpv6(t)) return null;
      host = '[$t]';
    } else if (colons == 1) {
      final i = t.indexOf(':');
      host = t.substring(0, i);
      port = t.substring(i + 1);
      if (!_isHost(host)) return null;
    } else {
      host = t;
      if (!_isHost(host)) return null;
    }
  }
  final number = port == null ? defaultPhonePort : int.tryParse(port);
  if (number == null || number <= 0 || number >= 65536) return null;
  return '$host:$number';
}

bool _isIpv6(String text) =>
    text.contains(':') && RegExp(r'^[0-9A-Fa-f:.]+(%[\w.-]+)?$').hasMatch(text);

bool _isHost(String text) {
  if (text.isEmpty) return false;
  if (RegExp(r'^[\d.]+$').hasMatch(text)) {
    final parts = text.split('.');
    return parts.length == 4 &&
        parts.every((p) {
          final n = int.tryParse(p);
          return p.isNotEmpty && n != null && n <= 255;
        });
  }
  return RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\.?$',
  ).hasMatch(text);
}

String pairedPhoneLabel(String key, Map<String, String> names) {
  final saved = names[key];
  if (saved != null && saved.isNotEmpty) return saved;
  if (key.startsWith('addr:')) return key.substring(5);
  var name = key.replaceAll(r'\032', ' ');
  final service = name.indexOf('._conectdroidcam.');
  if (service > 0) name = name.substring(0, service);
  const prefix = 'ConectDroidCam ';
  if (name.startsWith(prefix) && name.length > prefix.length) {
    name = name.substring(prefix.length);
  }
  return name;
}
