import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/receiver_platform.dart';
import '../data/receiver_settings_store.dart';
import '../data/rust_receiver_platform.dart';
import '../domain/receiver_models.dart';

enum ReceiverPhase {
  /// Carregando o núcleo.
  starting,

  /// O núcleo não carregou; veja [ReceiverState.error].
  unavailable,

  /// Pronto, sem celular conectado.
  idle,

  /// Abrindo a conexão.
  connecting,

  /// Recebendo vídeo de um celular.
  connected,
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
    this.connectedTo,
    this.phoneName,
    this.phonePlatform,
    this.incoming,
    this.outgoing,
    this.stats,
    this.notice,
    this.error,
    this.discoveryError,
  });

  final ReceiverPhase phase;
  final List<Phone> phones;
  final List<VideoDevice> devices;

  /// Dispositivo escolhido: [ReceiverController.automaticDevice] para usar a webcam do
  /// tamanho e formato certos, o caminho de um dispositivo específico, ou `null` para só
  /// medir a conexão.
  final String? selectedDevice;

  /// Formato do quadro entregue à webcam virtual.
  final ImageFormat format;

  /// Tamanho do quadro entregue à webcam virtual (não acompanha o celular).
  final OutputSize outputSize;
  final bool ffmpegOk;

  /// Conectar sozinho a um celular já usado quando ele aparecer na rede.
  final bool autoConnect;

  /// Celulares a que o usuário já conectou (identificadores mDNS).
  final Set<String> trustedPhones;

  /// Endereço do celular conectado.
  final String? connectedTo;
  final String? phoneName;
  final String? phonePlatform;
  final IncomingVideo? incoming;
  final OutgoingVideo? outgoing;
  final LiveStats? stats;

  /// Aviso que não interrompe a conexão.
  final String? notice;

  /// Falha que o usuário precisa ver.
  final String? error;
  final String? discoveryError;

  bool get isBusy =>
      phase == ReceiverPhase.connecting || phase == ReceiverPhase.connected;

  /// Existe algum dispositivo criado pelo script de instalação?
  bool get hasConectDroidCamDevice => devices.any((d) => d.isConectDroidCam);

  /// Existem as webcams por tamanho e formato (uma para cada combinação)?
  bool get hasDeviceFamily => devices.any((d) => d.shape != null);

  /// As webcams por tamanho e formato, para o núcleo escolher a certa.
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
    String? Function()? connectedTo,
    String? Function()? phoneName,
    String? Function()? phonePlatform,
    IncomingVideo? Function()? incoming,
    OutgoingVideo? Function()? outgoing,
    LiveStats? Function()? stats,
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
      connectedTo: connectedTo != null ? connectedTo() : this.connectedTo,
      phoneName: phoneName != null ? phoneName() : this.phoneName,
      phonePlatform: phonePlatform != null
          ? phonePlatform()
          : this.phonePlatform,
      incoming: incoming != null ? incoming() : this.incoming,
      outgoing: outgoing != null ? outgoing() : this.outgoing,
      stats: stats != null ? stats() : this.stats,
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

/// O último quadro da prévia. Fica fora do estado principal para a tela inteira não ser
/// reconstruída a cada quadro (cerca de 10 por segundo).
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
  /// Valor de [ReceiverState.selectedDevice] que escolhe a webcam por tamanho e formato.
  static const automaticDevice = 'auto';

  late ReceiverPlatform _platform;
  late ReceiverSettingsStore _store;
  StreamSubscription<PhoneChange>? _discovery;
  StreamSubscription<ReceiverUpdate>? _session;
  Timer? _rediscover;

  /// Identificador do celular da conexão atual, para lembrá-lo e para não reconectar
  /// sozinho a um celular que o usuário acabou de desconectar.
  String? _connectedId;

  /// Celulares a que não se conecta sozinho até eles saírem da rede e voltarem: o usuário
  /// desconectou de propósito, ou a conexão acabou de falhar.
  final Set<String> _noAuto = {};

  @override
  ReceiverState build() {
    // Guardados aqui porque o Riverpod não deixa usar `ref` dentro de `onDispose`.
    final platform = _platform = ref.read(receiverPlatformProvider);
    _store = ref.read(receiverSettingsStoreProvider);
    final preview = ref.read(previewFrameProvider.notifier);
    ref.onDispose(() {
      _rediscover?.cancel();
      _discovery?.cancel();
      _session?.cancel();
      unawaited(platform.disconnect().catchError((Object _) {}));
      unawaited(platform.stopDiscovery().catchError((Object _) {}));
      // O notifier da prévia pode já ter sido descartado junto.
      try {
        preview.update(null);
      } on Object catch (_) {}
    });
    return const ReceiverState();
  }

  /// Carrega o núcleo, confere o `ffmpeg`, lista as webcams virtuais e começa a procurar
  /// celulares.
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
      // Prefere a escolha automática (uma webcam por tamanho e formato); sem ela, o
      // dispositivo único das versões anteriores; sem nenhum, só medir.
      choice = family
          ? automaticDevice
          : devices
                .where((d) => d.isConectDroidCam)
                .map((d) => d.path)
                .firstOrNull;
    }
    state = state.copyWith(devices: devices, selectedDevice: () => choice);
  }

  /// Quanto esperar antes de procurar de novo quando a lista continua vazia. O mDNS recua
  /// as consultas (1, 2, 4, 8, 16 s...) e um celular que demorou a responder à primeira
  /// só seria achado muito depois.
  static const rediscoverEvery = Duration(seconds: 8);

  void _startDiscovery() {
    _rediscover?.cancel();
    _rediscover = Timer.periodic(rediscoverEvery, (_) {
      if (state.phase == ReceiverPhase.idle && state.phones.isEmpty) {
        _restartDiscovery();
      }
    });
    // A primeira busca se inscreve na hora: um celular que apareça logo depois não pode se perder.
    _subscribeDiscovery();
  }

  /// Procura de novo agora, sem esperar o recuo das consultas.
  Future<void> rediscover() async {
    // Quem já saiu da rede não avisaria mais depois de a busca reiniciar: recomeça limpo.
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
          // Saiu da rede: quando voltar, pode reconectar sozinho de novo.
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

  /// Conecta sozinho a um celular já usado, se isso estiver ligado e não houver motivo
  /// para esperar.
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

  /// Escolhe o formato da imagem. Com o celular conectado, reconecta para o novo formato
  /// valer: o tamanho da webcam virtual é fixo dentro de uma sessão.
  Future<void> setFormat(ImageFormat value) async {
    if (value == state.format) return;
    state = state.copyWith(format: value);
    await _saveSettings();
    if (state.isBusy) await _reconnect();
  }

  /// Escolhe o tamanho da imagem entregue à webcam virtual. Com o celular conectado,
  /// reconecta para valer.
  Future<void> setOutputSize(OutputSize value) async {
    if (value == state.outputSize) return;
    state = state.copyWith(outputSize: value);
    await _saveSettings();
    if (state.isBusy) await _reconnect();
  }

  /// Desconecta e conecta de novo ao mesmo celular, sem contar como desconexão do usuário.
  Future<void> _reconnect() async {
    final address = state.connectedTo;
    if (address == null) return;
    final name = state.phoneName;
    final id = _connectedId;
    await _platform.disconnect();
    // Espera a sessão terminar de verdade antes de abrir a próxima.
    for (var i = 0; i < 100 && state.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (id != null) _noAuto.remove(id);
    await connect(address, name: name, id: id);
  }

  /// Liga ou desliga a conexão automática a celulares já usados.
  Future<void> setAutoConnect(bool value) async {
    state = state.copyWith(autoConnect: value);
    await _saveSettings();
    if (value) {
      // Já pode haver um celular usado na lista.
      for (final phone in state.phones) {
        _maybeAutoConnect(phone);
      }
    }
  }

  /// Esquece todos os celulares lembrados.
  Future<void> forgetPhones() async {
    state = state.copyWith(trustedPhones: const {});
    await _saveSettings();
  }

  Future<void> _saveSettings() => _store.save(
    ReceiverSettings(
      autoConnect: state.autoConnect,
      trustedPhones: state.trustedPhones,
      format: state.format,
      outputSize: state.outputSize,
    ),
  );

  /// Conecta a um celular pelo endereço `ip:porta`. [id] identifica o celular, quando ele
  /// veio da lista, para lembrá-lo depois de conectar.
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
        )
        .listen(
          _onUpdate,
          onError: (Object e) => _finish(error: '$e'),
          // O núcleo sempre termina com Ended ou Failed; se o fluxo fechar sem isso (a
          // thread caiu), a tela não pode ficar presa em "conectando".
          onDone: () {
            if (state.isBusy) {
              _finish(error: 'A conexão terminou de forma inesperada.');
            }
          },
        );
  }

  bool _looksLikeAddress(String text) {
    final i = text.lastIndexOf(':');
    if (i <= 0 || i == text.length - 1) return false;
    final port = int.tryParse(text.substring(i + 1));
    return port != null && port > 0 && port < 65536;
  }

  /// Desconecta por vontade do usuário: não reconecta sozinho a este celular até ele sair
  /// da rede e voltar.
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
        _rememberConnectedPhone();
      case ProfileUpdate(:final video):
        state = state.copyWith(
          phase: ReceiverPhase.connected,
          incoming: () => video,
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
        // O celular ainda pode estar na lista por um instante depois de parar; sem isto,
        // a conexão automática tentaria de novo e falharia. Vale até ele sair e voltar.
        if (_connectedId case final id?) _noAuto.add(id);
        _finish();
      case FailedUpdate(:final message):
        // Não tenta de novo sozinho em loop: espera o celular sair e voltar.
        if (_connectedId case final id?) _noAuto.add(id);
        _finish(error: message);
    }
  }

  /// Lembra o celular a que acabamos de conectar, para reconectar sozinho da próxima vez.
  void _rememberConnectedPhone() {
    final id = _connectedId;
    if (id == null || state.trustedPhones.contains(id)) return;
    state = state.copyWith(trustedPhones: {...state.trustedPhones, id});
    unawaited(_saveSettings());
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
      error: error != null ? () => error : null,
    );
  }
}
