import 'dart:async';

import 'package:conectdroidcam/features/sender/data/sender_platform.dart';
import 'package:conectdroidcam/features/sender/domain/sender_models.dart';

/// Emissor nativo de mentira, para testar o controlador sem câmera.
class FakeSenderPlatform implements SenderPlatform {
  bool permissionGranted = false;
  bool grantOnRequest = true;
  int permissionRequests = 0;
  int previewStarts = 0;
  int streamStarts = 0;
  int streamStops = 0;
  VideoMode? lastStreamedMode;
  int? lastStreamedFps;
  final List<int> setFpsCalls = [];
  SenderException? startPreviewError;
  SenderException? startStreamingError;
  SenderException? setFpsError;

  /// Um aparelho parecido com o de teste: HD e Full HD ok, 2K indisponível,
  /// e duas resoluções extras (uma que só chega a 20 FPS).
  SenderCapabilities capabilities = const SenderCapabilities(
    fpsOptions: [15, 20, 30],
    modes: [
      ModeAvailability(mode: VideoMode.hd, available: true),
      ModeAvailability(mode: VideoMode(1920, 1080), available: true),
      ModeAvailability(
        mode: VideoMode.qhd,
        available: false,
        reason: 'sem codificador H.264 por hardware para 2560×1440',
      ),
      ModeAvailability(mode: VideoMode(1920, 1440), available: true),
      ModeAvailability(mode: VideoMode.uhd, available: true),
      ModeAvailability(
        mode: VideoMode(4000, 2256),
        available: true,
        maxFps: 20,
      ),
      ModeAvailability(
        mode: VideoMode(4000, 3000),
        available: false,
        reason: 'sem codificador H.264 por hardware para 4000×3000',
      ),
    ],
  );

  final _events = StreamController<SenderEvent>.broadcast();

  void emit(SenderEvent event) => _events.add(event);

  @override
  Future<bool> hasCameraPermission() async => permissionGranted;

  @override
  Future<bool> requestCameraPermission() async {
    permissionRequests++;
    permissionGranted = grantOnRequest;
    return permissionGranted;
  }

  @override
  Future<SenderCapabilities> listModes() async => capabilities;

  @override
  Future<List<LocalAddress>> localAddresses() async => const [
    LocalAddress(interfaceName: 'rmnet0', address: '10.0.0.5'),
    LocalAddress(interfaceName: 'wlan0', address: '192.168.0.7'),
  ];

  @override
  Future<PreviewInfo> startPreview() async {
    final error = startPreviewError;
    if (error != null) throw error;
    previewStarts++;
    return const PreviewInfo(textureId: 1, width: 1280, height: 720);
  }

  @override
  Future<void> stopPreview() async {}

  @override
  Future<StreamInfo> startStreaming(VideoMode mode, int fps) async {
    final error = startStreamingError;
    if (error != null) throw error;
    streamStarts++;
    lastStreamedMode = mode;
    lastStreamedFps = fps;
    return StreamInfo(mode: mode, fps: fps, bitrateKbps: 3000, port: 47821);
  }

  @override
  Future<void> setFps(int fps) async {
    final error = setFpsError;
    if (error != null) throw error;
    setFpsCalls.add(fps);
  }

  @override
  Future<void> stopStreaming() async => streamStops++;

  @override
  Stream<SenderEvent> get events => _events.stream;
}
