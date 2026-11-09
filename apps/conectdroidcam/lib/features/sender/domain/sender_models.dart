/// Uma resolução de vídeo.
class VideoMode {
  const VideoMode(this.width, this.height);

  final int width;
  final int height;

  static const hd = VideoMode(1280, 720);
  static const fullHd = VideoMode(1920, 1080);
  static const qhd = VideoMode(2560, 1440);
  static const uhd = VideoMode(3840, 2160);

  /// As três resoluções principais, sempre mostradas na tela.
  static const main = [hd, fullHd, qhd];

  bool get isMain => main.contains(this);

  /// Nome comercial, ou vazio para resoluções sem nome conhecido.
  String get name {
    if (this == hd) return 'HD';
    if (this == fullHd) return 'Full HD';
    if (this == qhd) return '2K';
    if (this == uhd) return '4K';
    return '';
  }

  /// Texto mostrado ao usuário. O "2K" sempre aparece com a resolução.
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

/// Se uma resolução pode ser usada neste aparelho, e o motivo quando não pode.
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

  /// Maior FPS que a câmera sustenta nesta resolução.
  final int maxFps;
}

/// O que este aparelho oferece, descoberto pela câmera e pelo codificador.
class SenderCapabilities {
  const SenderCapabilities({required this.modes, required this.fpsOptions});

  /// Todas as resoluções que passam do piso de 720p, com a disponibilidade de cada uma.
  final List<ModeAvailability> modes;

  /// FPS fixos que a câmera aceita, em ordem crescente.
  final List<int> fpsOptions;

  static const empty = SenderCapabilities(modes: [], fpsOptions: [30]);

  ModeAvailability? find(VideoMode mode) {
    for (final item in modes) {
      if (item.mode == mode) return item;
    }
    return null;
  }

  /// HD, Full HD e 2K, nesta ordem. Se a câmera não oferece uma delas, aparece
  /// indisponível com o motivo, em vez de sumir.
  List<ModeAvailability> get mainModes => [
    for (final mode in VideoMode.main)
      find(mode) ??
          ModeAvailability(
            mode: mode,
            available: false,
            reason: 'a câmera não oferece ${mode.width}×${mode.height}',
          ),
  ];

  /// Demais resoluções utilizáveis, da menor para a maior.
  List<ModeAvailability> get extraModes =>
      modes.where((m) => m.available && !m.mode.isMain).toList()
        ..sort((a, b) => a.mode.pixels.compareTo(b.mode.pixels));

  /// FPS que dá para usar nesta resolução.
  List<int> fpsFor(VideoMode mode) {
    final max = find(mode)?.maxFps ?? 30;
    final options = fpsOptions.where((f) => f <= max).toList();
    return options.isEmpty ? [max] : options;
  }

  /// O FPS desejado, ajustado ao que a resolução sustenta: o maior que não passa dele.
  int clampFps(VideoMode mode, int desired) {
    final options = fpsFor(mode);
    final fitting = options.where((f) => f <= desired).toList();
    return fitting.isEmpty ? options.first : fitting.last;
  }
}

/// Câmera aberta para a prévia: textura do Flutter e como orientá-la.
///
/// O Camera2 entrega a textura já alinhada à orientação natural do aparelho
/// (retrato, na maioria dos celulares). Com a tela em paisagem é preciso girá-la de
/// volta, senão a imagem aparece espremida e deitada.
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

  /// Tamanho do buffer da câmera, em paisagem (como o sensor entrega).
  final int width;
  final int height;

  /// Quanto o sensor está girado em relação à orientação natural: 0, 90, 180 ou 270.
  final int sensorOrientation;

  /// Rotação da tela: 0, 1, 2 ou 3 (0°, 90°, 180°, 270° como em `Surface.ROTATION_*`).
  final int displayRotation;

  /// A câmera em uso é a frontal. Só a prévia sai espelhada; o vídeo enviado não.
  final bool isFront;

  /// O aparelho tem câmera frontal e traseira.
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

  /// Sensores girados 90° ou 270° entregam a textura com largura e altura trocadas.
  bool get _swapsAxes => sensorOrientation % 180 != 0;

  /// Proporção da textura como ela chega, antes de girar.
  double get textureAspectRatio {
    if (height == 0 || width == 0) return 16 / 9;
    return _swapsAxes ? height / width : width / height;
  }

  /// Giros de 90° no sentido horário para deixar a imagem em pé na tela atual.
  int get quarterTurns => switch (displayRotation) {
    1 => 3,
    2 => 2,
    3 => 1,
    _ => 0,
  };
}

/// O que o emissor realmente está entregando.
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

/// Endereço IPv4 de uma interface de rede do celular.
class LocalAddress {
  const LocalAddress({required this.interfaceName, required this.address});

  final String interfaceName;
  final String address;

  /// Interfaces de Wi-Fi e Ethernet; dados móveis (rmnet) não servem para a rede local.
  bool get isLan =>
      interfaceName.startsWith('wlan') ||
      interfaceName.startsWith('eth') ||
      interfaceName.startsWith('ap');
}

/// Eventos que chegam do código nativo durante a transmissão.
sealed class SenderEvent {
  const SenderEvent();
}

class ClientEvent extends SenderEvent {
  const ClientEvent({required this.connected, this.peer});

  final bool connected;
  final String? peer;
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

/// A tela girou; a prévia precisa ser reorientada.
class RotationEvent extends SenderEvent {
  const RotationEvent(this.displayRotation);

  final int displayRotation;
}

/// Resultado de anunciar o celular na rede local (mDNS).
class DiscoveryEvent extends SenderEvent {
  const DiscoveryEvent({required this.registered, this.name, this.error});

  final bool registered;

  /// Nome com que o celular aparece para o computador.
  final String? name;
  final String? error;
}

class ErrorEvent extends SenderEvent {
  const ErrorEvent(this.message);

  final String message;
}
