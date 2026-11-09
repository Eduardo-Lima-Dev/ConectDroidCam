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
  SenderException? startPreviewError;
  SenderException? startStreamingError;

  List<ProfileAvailability> profiles = const [
    ProfileAvailability(profile: VideoProfile.hd, available: true),
    ProfileAvailability(profile: VideoProfile.fullHd, available: true),
    ProfileAvailability(
      profile: VideoProfile.qhd,
      available: false,
      reason: 'a câmera não oferece 2560×1440',
    ),
  ];

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
  Future<List<ProfileAvailability>> listProfiles() async => profiles;

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
  Future<StreamInfo> startStreaming(VideoProfile profile) async {
    final error = startStreamingError;
    if (error != null) throw error;
    streamStarts++;
    return StreamInfo(
      profile: profile,
      width: profile.width,
      height: profile.height,
      fps: 30,
      bitrateKbps: profile.bitrateKbps,
      port: 47821,
    );
  }

  @override
  Future<void> stopStreaming() async => streamStops++;

  @override
  Stream<SenderEvent> get events => _events.stream;
}
