class VideoMode {
  const VideoMode(this.width, this.height);

  final int width;
  final int height;

  static const hd = VideoMode(1280, 720);
  static const fullHd = VideoMode(1920, 1080);
  static const qhd = VideoMode(2560, 1440);
  static const uhd = VideoMode(3840, 2160);

  static const main = [hd, fullHd, qhd];

  bool get isMain => main.contains(this);

  String get name {
    if (this == hd) return 'HD';
    if (this == fullHd) return 'Full HD';
    if (this == qhd) return '2K';
    if (this == uhd) return '4K';
    return '';
  }

  String get label =>
      name.isEmpty ? '$width×$height' : '$name ($width×$height)';

  int get pixels => width * height;

  @override
  bool operator ==(Object other) =>
      other is VideoMode && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'VideoMode($width×$height)';
}

class ModeAvailability {
  const ModeAvailability({
    required this.mode,
    required this.available,
    this.reason,
    this.maxFps = 30,
  });

  final VideoMode mode;
  final bool available;
  final String? reason;

  final int maxFps;
}

class SenderCapabilities {
  const SenderCapabilities({required this.modes, required this.fpsOptions});

  final List<ModeAvailability> modes;

  final List<int> fpsOptions;

  static const empty = SenderCapabilities(modes: [], fpsOptions: [30]);

  ModeAvailability? find(VideoMode mode) {
    for (final item in modes) {
      if (item.mode == mode) return item;
    }
    return null;
  }

  List<ModeAvailability> get mainModes => [
    for (final mode in VideoMode.main)
      find(mode) ??
          ModeAvailability(
            mode: mode,
            available: false,
            reason: 'a câmera não oferece ${mode.width}×${mode.height}',
          ),
  ];

  List<ModeAvailability> get extraModes =>
      modes.where((m) => m.available && !m.mode.isMain).toList()
        ..sort((a, b) => a.mode.pixels.compareTo(b.mode.pixels));

  List<int> fpsFor(VideoMode mode) {
    final max = find(mode)?.maxFps ?? 30;
    final options = fpsOptions.where((f) => f <= max).toList();
    return options.isEmpty ? [max] : options;
  }

  int clampFps(VideoMode mode, int desired) {
    final options = fpsFor(mode);
    final fitting = options.where((f) => f <= desired).toList();
    return fitting.isEmpty ? options.first : fitting.last;
  }
}

class PreviewInfo {
  const PreviewInfo({
    required this.textureId,
    required this.width,
    required this.height,
    this.sensorOrientation = 90,
    this.displayRotation = 0,
    this.isFront = false,
    this.canSwitch = false,
  });

  final int textureId;

  final int width;
  final int height;

  final int sensorOrientation;

  final int displayRotation;

  final bool isFront;

  final bool canSwitch;

  PreviewInfo copyWith({int? displayRotation}) => PreviewInfo(
    textureId: textureId,
    width: width,
    height: height,
    sensorOrientation: sensorOrientation,
    displayRotation: displayRotation ?? this.displayRotation,
    isFront: isFront,
    canSwitch: canSwitch,
  );

  bool get _swapsAxes => sensorOrientation % 180 != 0;

  double get textureAspectRatio {
    if (height == 0 || width == 0) return 16 / 9;
    return _swapsAxes ? height / width : width / height;
  }

  int get quarterTurns => switch (displayRotation) {
    1 => 3,
    2 => 2,
    3 => 1,
    _ => 0,
  };
}

class PairedComputer {
  const PairedComputer({
    required this.fingerprint,
    required this.name,
    required this.since,
  });

  final String fingerprint;
  final String name;
  final DateTime since;

  String get shortFingerprint => fingerprint
      .substring(0, fingerprint.length < 16 ? fingerprint.length : 16)
      .replaceAllMapped(RegExp('.{4}'), (m) => '${m[0]} ')
      .trim();
}

class StreamInfo {
  const StreamInfo({
    required this.mode,
    required this.fps,
    required this.bitrateKbps,
    required this.port,
  });

  final VideoMode mode;
  final int fps;
  final int bitrateKbps;
  final int port;

  int get width => mode.width;
  int get height => mode.height;
}

class LocalAddress {
  const LocalAddress({required this.interfaceName, required this.address});

  final String interfaceName;
  final String address;

  bool get isLan =>
      interfaceName.startsWith('wlan') ||
      interfaceName.startsWith('eth') ||
      interfaceName.startsWith('ap');
}

sealed class SenderEvent {
  const SenderEvent();
}

class ClientEvent extends SenderEvent {
  const ClientEvent({required this.connected, this.peer, this.name});

  final bool connected;
  final String? peer;
  final String? name;
}

class StatsEvent extends SenderEvent {
  const StatsEvent({
    required this.fps,
    required this.bitrateKbps,
    required this.dropped,
  });

  final double fps;
  final double bitrateKbps;
  final int dropped;
}

class RotationEvent extends SenderEvent {
  const RotationEvent(this.displayRotation);

  final int displayRotation;
}

class DiscoveryEvent extends SenderEvent {
  const DiscoveryEvent({required this.registered, this.name, this.error});

  final bool registered;

  final String? name;
  final String? error;
}

class RemoteStreamEvent extends SenderEvent {
  const RemoteStreamEvent({required this.streaming, this.stream});

  final bool streaming;

  final StreamInfo? stream;
}

class CameraChangedEvent extends SenderEvent {
  const CameraChangedEvent(this.preview);

  final PreviewInfo preview;
}

class PairingRequestEvent extends SenderEvent {
  const PairingRequestEvent({required this.code, required this.computer});

  final String code;
  final String computer;
}

class PairingEndedEvent extends SenderEvent {
  const PairingEndedEvent({
    required this.paired,
    required this.computer,
    this.reason,
  });

  final bool paired;
  final String computer;
  final String? reason;
}

class ErrorEvent extends SenderEvent {
  const ErrorEvent(this.message, {this.recoverable = false});

  final String message;
  final bool recoverable;
}
