import 'dart:async';

import 'package:conectdroidcam/features/receiver/data/receiver_platform.dart';
import 'package:conectdroidcam/features/receiver/data/receiver_settings_store.dart';
import 'package:conectdroidcam/features/receiver/domain/receiver_models.dart';

/// Núcleo do receptor de mentira: sem Rust, sem rede e sem webcam virtual.
class FakeReceiverPlatform implements ReceiverPlatform {
  Object? initError;
  bool ffmpeg = true;

  /// A família completa, como o script de instalação a cria, mais um dispositivo comum.
  List<VideoDevice> devices = const [
    VideoDevice(path: '/dev/video0', name: 'Dummy video device (0x0000)'),
    VideoDevice(path: '/dev/video10', name: 'ConectDroidCam FHD Horizontal'),
    VideoDevice(path: '/dev/video11', name: 'ConectDroidCam FHD Vertical'),
    VideoDevice(path: '/dev/video12', name: 'ConectDroidCam HD Horizontal'),
    VideoDevice(path: '/dev/video13', name: 'ConectDroidCam HD Vertical'),
    VideoDevice(path: '/dev/video14', name: 'ConectDroidCam 2K Horizontal'),
    VideoDevice(path: '/dev/video15', name: 'ConectDroidCam 2K Vertical'),
  ];

  int initCalls = 0;
  int disconnects = 0;
  int connects = 0;

  /// Quantas vezes a busca foi (re)iniciada.
  int discoveries = 0;
  String? lastAddress;
  String? lastDevice;
  ImageFormat? lastFormat;
  OutputSize? lastSize;
  List<ShapeDevice>? lastShapeDevices;
  Object? discoverError;

  final _phones = StreamController<PhoneChange>.broadcast();
  StreamController<ReceiverUpdate>? _session;

  void phoneFound(Phone phone) => _phones.add(PhoneChange.found(phone));
  void phoneLost(String id) => _phones.add(PhoneChange.lost(id));
  void send(ReceiverUpdate update) => _session?.add(update);
  Future<void> endSession() async => _session?.close();

  @override
  Future<void> init() async {
    initCalls++;
    if (initError != null) throw initError!;
  }

  @override
  Stream<PhoneChange> discover() {
    discoveries++;
    final error = discoverError;
    if (error != null) return Stream.error(error);
    return _phones.stream;
  }

  @override
  Future<void> stopDiscovery() async {}

  @override
  Stream<ReceiverUpdate> connect({
    required String address,
    required String? videoDevice,
    required ImageFormat format,
    required OutputSize size,
    required List<ShapeDevice> shapeDevices,
  }) {
    connects++;
    lastAddress = address;
    lastDevice = videoDevice;
    lastFormat = format;
    lastSize = size;
    lastShapeDevices = shapeDevices;
    _session = StreamController<ReceiverUpdate>();
    return _session!.stream;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    send(const EndedUpdate());
  }

  /// Comandos enviados ao celular, em ordem: `start 1920x1080@30`, `stop`, `fps 24`,
  /// `camera front|back|toggle`.
  final List<String> commands = [];

  /// Se não for `null`, todo comando falha com este motivo.
  String? commandError;

  Future<String?> _command(String text) async {
    commands.add(text);
    return commandError;
  }

  @override
  Future<String?> startStream(int width, int height, int fps) =>
      _command('start ${width}x$height@$fps');

  @override
  Future<String?> stopStream() => _command('stop');

  @override
  Future<String?> setFps(int fps) => _command('fps $fps');

  @override
  Future<String?> switchCamera({bool? front}) => _command(
    'camera ${front == null
        ? 'toggle'
        : front
        ? 'front'
        : 'back'}',
  );

  @override
  Future<bool> ffmpegAvailable() async => ffmpeg;

  @override
  Future<List<VideoDevice>> listVideoDevices() async => devices;

  @override
  Future<String> computerName() async => 'pc-teste';
}

/// Configurações em memória, sem tocar no disco.
class FakeSettingsStore implements ReceiverSettingsStore {
  FakeSettingsStore([this.settings = const ReceiverSettings()]);

  ReceiverSettings settings;
  int saves = 0;

  @override
  Future<ReceiverSettings> load() async => settings;

  @override
  Future<void> save(ReceiverSettings value) async {
    saves++;
    settings = value;
  }
}
