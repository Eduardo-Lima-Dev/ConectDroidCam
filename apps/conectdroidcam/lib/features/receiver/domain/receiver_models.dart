import 'dart:typed_data';

class Phone {
  const Phone({required this.id, required this.name, required this.address});

  final String id;
  final String name;

  final String address;
}

class ShapeDevice {
  const ShapeDevice({
    required this.size,
    required this.vertical,
    required this.path,
  });

  final OutputSize size;
  final bool vertical;
  final String path;
}

class VideoDevice {
  const VideoDevice({required this.path, required this.name});

  final String path;
  final String name;

  bool get isConectDroidCam => name.contains('ConectDroidCam');

  static final _shapeName = RegExp(
    r'^ConectDroidCam (HD|FHD|2K) (Horizontal|Vertical)$',
  );

  ShapeDevice? get shape {
    final m = _shapeName.firstMatch(name);
    if (m == null) return null;
    final size = switch (m.group(1)) {
      'HD' => OutputSize.hd,
      '2K' => OutputSize.qhd,
      _ => OutputSize.fullHd,
    };
    return ShapeDevice(
      size: size,
      vertical: m.group(2) == 'Vertical',
      path: path,
    );
  }

  String get label => '$name ($path)';
}

class IncomingVideo {
  const IncomingVideo({
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
    required this.rotation,
  });

  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;

  final int rotation;
}

class OutgoingVideo {
  const OutgoingVideo({
    required this.width,
    required this.height,
    required this.rotation,
    this.device,
  });

  final String? device;

  final int width;
  final int height;
  final int rotation;
}

class LiveStats {
  const LiveStats({
    required this.fps,
    required this.kbps,
    required this.delayMs,
    required this.frames,
  });

  final double fps;
  final double kbps;

  final double delayMs;
  final int frames;
}

class PhoneMode {
  const PhoneMode({
    required this.width,
    required this.height,
    required this.available,
    this.maxFps = 30,
    this.reason,
  });

  final int width;
  final int height;
  final bool available;
  final int maxFps;
  final String? reason;

  String get label => '$width×$height';

  @override
  bool operator ==(Object other) =>
      other is PhoneMode && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

class PhoneCapabilities {
  const PhoneCapabilities({
    required this.modes,
    required this.fpsOptions,
    required this.front,
    required this.canSwitch,
    required this.streaming,
  });

  final List<PhoneMode> modes;
  final List<int> fpsOptions;

  final bool front;
  final bool canSwitch;

  final bool streaming;

  PhoneMode? find(int width, int height) =>
      modes.where((m) => m.width == width && m.height == height).firstOrNull;

  List<PhoneMode> get availableModes =>
      modes.where((m) => m.available).toList()
        ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
}

sealed class ReceiverUpdate {
  const ReceiverUpdate();
}

class HelloUpdate extends ReceiverUpdate {
  const HelloUpdate({required this.deviceName, required this.platform});

  final String deviceName;
  final String platform;
}

class CapabilitiesUpdate extends ReceiverUpdate {
  const CapabilitiesUpdate(this.capabilities);

  final PhoneCapabilities capabilities;
}

class PairingCodeUpdate extends ReceiverUpdate {
  const PairingCodeUpdate({required this.code, required this.phoneFingerprint});

  final String code;
  final String phoneFingerprint;
}

class PairedUpdate extends ReceiverUpdate {
  const PairedUpdate(this.phoneFingerprint);

  final String phoneFingerprint;
}

class PairingDeniedUpdate extends ReceiverUpdate {
  const PairingDeniedUpdate(this.reason);

  final String reason;
}

class ProfileUpdate extends ReceiverUpdate {
  const ProfileUpdate(this.video);

  final IncomingVideo video;
}

class OutputUpdate extends ReceiverUpdate {
  const OutputUpdate(this.video);

  final OutgoingVideo video;
}

class StatsUpdate extends ReceiverUpdate {
  const StatsUpdate(this.stats);

  final LiveStats stats;
}

class PreviewUpdate extends ReceiverUpdate {
  const PreviewUpdate(this.jpeg);

  final Uint8List jpeg;
}

class SenderErrorUpdate extends ReceiverUpdate {
  const SenderErrorUpdate(this.message);

  final String message;
}

class NoticeUpdate extends ReceiverUpdate {
  const NoticeUpdate(this.message);

  final String message;
}

class EndedUpdate extends ReceiverUpdate {
  const EndedUpdate();
}

class FailedUpdate extends ReceiverUpdate {
  const FailedUpdate(this.message);

  final String message;
}

class PhoneChange {
  const PhoneChange.found(Phone this.phone) : lostId = null;
  const PhoneChange.lost(String this.lostId) : phone = null;

  final Phone? phone;
  final String? lostId;
}

enum ImageFormat { auto, horizontal, vertical }

enum OutputSize {
  hd('HD', 1280, 720),
  fullHd('Full HD', 1920, 1080),
  qhd('2K', 2560, 1440);

  const OutputSize(this.title, this.long, this.short);

  final String title;
  final int long;
  final int short;

  String get label => '$title ($long×$short)';
}

class ReceiverSettings {
  const ReceiverSettings({
    this.autoConnect = true,
    this.trustedPhones = const {},
    this.fingerprints = const {},
    this.format = ImageFormat.auto,
    this.outputSize = OutputSize.fullHd,
  });

  final Map<String, String> fingerprints;

  final ImageFormat format;

  final OutputSize outputSize;

  final bool autoConnect;

  final Set<String> trustedPhones;

  ReceiverSettings copyWith({
    bool? autoConnect,
    Set<String>? trustedPhones,
    Map<String, String>? fingerprints,
    ImageFormat? format,
    OutputSize? outputSize,
  }) => ReceiverSettings(
    fingerprints: fingerprints ?? this.fingerprints,
    autoConnect: autoConnect ?? this.autoConnect,
    trustedPhones: trustedPhones ?? this.trustedPhones,
    format: format ?? this.format,
    outputSize: outputSize ?? this.outputSize,
  );
}
