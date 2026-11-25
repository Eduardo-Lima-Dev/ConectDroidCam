import '../domain/receiver_models.dart';

abstract interface class ReceiverPlatform {
  Future<void> init();

  Stream<PhoneChange> discover();
  Future<void> stopDiscovery();

  Stream<ReceiverUpdate> connect({
    required String address,
    required String? videoDevice,
    required ImageFormat format,
    required OutputSize size,
    required List<ShapeDevice> shapeDevices,

    String? pinnedFingerprint,
  });

  Future<void> disconnect();

  Future<String?> startIdleFeed(String device, int width, int height);

  Future<void> stopIdleFeed();

  Future<String?> confirmPairing(bool accept);

  Future<String?> startStream(int width, int height, int fps);

  Future<String?> stopStream();

  Future<String?> setFps(int fps);

  Future<String?> switchCamera({bool? front});

  Future<bool> ffmpegAvailable();

  Future<List<VideoDevice>> listVideoDevices();

  Future<String> computerName();
}
